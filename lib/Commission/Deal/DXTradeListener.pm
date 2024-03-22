package Commission::Deal::DXTradeListener;
use strict;
use warnings;

use parent qw(IO::Async::Notifier);

=head1 NAME

Commission::Deal::Listener - Listen to deals from a specific redis stream

=head1 SYNOPSIS

 use IO::Async::Loop;
 use Commission::Deal::Listener;
 $loop->add(
    my $listener = Commission::Deal::Listener->new(
        db_uri    => 'postgresql://write:PASS@HOST:PORT/DATABASE?sslmode=require',
        redis_uri => 'redis://127.0.0.1:6379',
        provider  => 'dxtrade',
    )
 );

$listener->start()->get();

=head1 DESCRIPTION

Listens to deals from redis stream and save them into commission database for later calculation

=cut

use Future::AsyncAwait;
use Net::Async::Redis;
use Database::Async;
use Database::Async::Engine::PostgreSQL;
use Syntax::Keyword::Try;

use JSON::MaybeXS qw(decode_json);
use YAML::XS      qw(LoadFile);
use Commission::Deal::DXTrade;
use Date::Utility;
use Log::Any                   qw($log);
use DataDog::DogStatsd::Helper qw(stats_inc);

=head2 new

Create a new instance.

=over 4

=item * redis_config - redis config file. Default to '/etc/rmg/redis-cfds.yml'

=item * redis_stream - the name of the stream to subscribe to. Default to 'mystream'

=item * redis_consumer_group - the redis consumer group. Default to 'mygroup'

=item * provider - the name of the stream provider. (required)

=item * db_service - a postgres service based on https://www.postgresql.org/docs/current/libpq-pgservice.html

=item * db_uri - a postgres connection string for commissiondb

=back

=cut

sub new {
    my ($class, %args) = @_;

    $args{redis_stream}         ||= 'mystream';
    $args{redis_consumer_group} ||= 'mygroup';
    $args{redis_config}         ||= '/etc/rmg/redis-cfds.yml';
    $args{db_service}           ||= 'commission01';

    die 'provider is required' unless $args{provider};

    my $self = {
        redis_config         => $args{redis_config},
        db_service           => $args{db_service},
        db_uri               => $args{db_uri},
        redis_stream         => $args{redis_stream},
        redis_consumer_group => $args{redis_consumer_group},
        provider             => $args{provider},
        _client_map          => {},
        _symbols_map         => {},
    };

    die "Please provide db_uri (eg. postgresql://localhost...) or db_service (e.g. cms01) arguments"
        if not defined $self->{db_uri} and not defined $self->{db_service};

    return bless $self, $class;
}

=head2 _add_to_loop

add redis and database to main loop

=cut

sub _add_to_loop {
    my $self = shift;

    my $config = LoadFile($self->{redis_config});
    my $redis  = Net::Async::Redis->new(
        host => $config->{write}{host},
        port => $config->{write}{port},
        auth => $config->{write}{password},
    );

    $self->{redis} = $redis;
    $self->add_child($redis);

    my %parameters = (
        pool => {
            max => 4,
        },
    );

    if ($self->{db_uri}) {
        $parameters{uri} = $self->{db_uri};
    } else {
        $parameters{engine} = {service => $self->{db_service}};
        $parameters{type}   = 'postgresql';
    }

    my $dbic = Database::Async->new(%parameters);

    $self->{dbic} = $dbic;
    $self->add_child($dbic);
}

=head2 start

Runs the listener

=cut

async sub start {
    my $self = shift;

    $log->infof('Starting listener for %s', $self->{provider});
    await $self->_load_client_map();
    $log->infof('Client map loaded');
    await $self->_load_symbols_map();
    $log->infof('Symbols map loaded');

    my $redis = $self->{redis};
    my $group = $self->{redis_consumer_group};

    try { await $redis->xgroup('CREATE', $self->{redis_stream}, $group, '$', 'MKSTREAM') } catch ($e) {
        $log->debugf("Consumer group %s already exists", $group);
    };

    # this stream is from RPC
    my $update_stream = $self->{provider} . '::real_signup';
    try { await $redis->xgroup('CREATE', $update_stream, $group, '$', 'MKSTREAM') } catch ($e) {
        $log->debugf("Consumer group %s already exists", $group);
    };

    $self->_check_pending_data_from_stream()->retain->on_fail(
        sub {
            $log->warnf("pending data stream not cleared %s", @_);
        });

    while (1) {
        try {
            # limit to one thousand inserts at a time.
            my $stream =
                await $redis->xreadgroup('GROUP', $group, 'any', 'BLOCK', 5000, 'COUNT', 1000, 'STREAMS', $self->{redis_stream},
                $update_stream, '>', '>');
            $log->debugf("stream received %s", $stream);
            if ($stream) {
                my ($stream_name, $stream_data) = $stream->[0]->@*;
                if ($stream_name eq $self->{redis_stream}) {
                    my $processed = await $self->_process_deals($stream_data);
                    $log->debugf("%s number of deals recorded.", $processed);
                } elsif ($stream_name eq $update_stream) {
                    await $self->_update_client_map($stream_data, $update_stream);
                }
            } else {
                $log->debugf("No deals founds. skipping... ");
            }
        } catch ($e) {
            $log->warnf("Exception thrown [%s]", $e);
            # prevent continuous polling from redis to max out cpu when redis servier is unavailable
            $self->loop->delay_future(after => 5);
        }
    }
}

=head2 _load_client_map

Load affiliate-client information from the commission database

=cut

async sub _load_client_map {
    my $self = shift;

    $log->debugf("loading from db for %s", $self->{provider});
    my $client_ids;

    try {
        $client_ids =
            await $self->{dbic}->query(q{SELECT id FROM affiliate.affiliate_client WHERE provider=$1}, $self->{provider})->row_hashrefs->as_arrayref;
        $log->debugf("loaded client ids %s", \$client_ids);
    } catch ($e) {
        $log->warnf("Exception thrown while loading client map [%s]", $e);
        # TODO: reconnection is needed while waiting for the patch on Database::Async. Remove after patch is applied
        await $self->_reconnect();
    }
    $self->{_client_map} = {map { $_->{id} => 1 } $client_ids->@*};
}

=head2 _load_symbols_map

Load instrument list from DevExperts REST API

=cut

async sub _load_symbols_map {
    my $self = shift;

    my $redis = $self->{redis};

    my $data = await $redis->hgetall('DERIVX_CONFIG::INSTRUMENT_LIST');

    return unless $data;

    my %symbols = $data->@*;
    my %symbols_map;
    foreach my $symbol (keys %symbols) {
        my $instrument_data = decode_json($symbols{$symbol});
        $symbols_map{$symbol} = $instrument_data->{currency};
        stats_inc('bom.commission.deal_listener.symbols_loaded.count');
    }

    $self->{_symbols_map} = \%symbols_map;

    return;
}

=head2 _update_client_map

Update affiliate-client information through data received from redis stream

=cut

async sub _update_client_map {
    my ($self, $client_ids, $update_stream) = @_;

    foreach my $data ($client_ids->@*) {
        my $id      = $data->[0];
        my %payload = $data->[1]->@*;
        $self->{_client_map}{$payload{account_id}} = 1;
        $log->debugf("%s added to client map", $payload{account_id});
        await $self->{redis}->xack($update_stream, $self->{redis_consumer_group}, $id);
        stats_inc('bom.commission.deal_listener.update_client_map.count');
    }
}

=head2 _process_deals

Parse deal data from stream and save them into transaction.deal table in commission database

=cut

async sub _process_deals {
    my ($self, $deals) = @_;

    my $number_of_deals_processed = 0;
    foreach my $data ($deals->@*) {
        my $id      = $data->[0];
        my %payload = $data->[1]->@*;
        $log->debugf("processing stream id %s with payload %s", $id, \%payload);
        my $dx_deal = Commission::Deal::DXTrade->new(%payload);

        try {

            # for deals from test accounts or from unaffiliated clients, we want to just acknowledge them but not saving them
            if (not $dx_deal->is_valid or $dx_deal->is_test_account or not $self->{_client_map}->{$dx_deal->loginid}) {
                my $reason = $dx_deal->is_test_account ? 'test account' : 'unaffiliated client';
                $log->debugf("skipping deal [%s] for stream id [%s], reason [%s]", $dx_deal->deal_id, $id, $reason);
                await $self->{redis}->xack($self->{redis_stream}, $self->{redis_consumer_group}, $id);
                next;
            }

            await $self->_insert_into_db($dx_deal);
            $log->debugf("deal [%s] for stream id %s saved", $dx_deal->deal_id, $id);
            await $self->{redis}->xack($self->{redis_stream}, $self->{redis_consumer_group}, $id);
            $number_of_deals_processed++;
            stats_inc('bom.commission.deal_listener.process_deals.successful.count',
                {tags => ["info:Successfull processing of $number_of_deals_processed deals"]});

        } catch ($e) {
            my $error_message = ref $e ? $e->message : $e;
            $log->warnf("exception thrown when processing deal for deal %s . [%s]", $dx_deal->deal_id, $error_message);
            stats_inc('bom.commission.deal_listener.process_deals.failed.count', {tags => ["error:$error_message"]});
        }

    }

    return $number_of_deals_processed;
}

=head2 _insert_into_db

Saves deal into commission db

=cut

async sub _insert_into_db {
    my ($self, $deal) = @_;

    my $deal_id;
    try {
        my $currency = $self->{_symbols_map}->{$deal->underlying_symbol};

        unless ($currency) {
            # It seems it we may have added a new symbol to product offerings. Reload symbols map and try again.
            await $self->_load_symbols_map();
            $currency = $self->{_symbols_map}->{$deal->underlying_symbol};
        }

        if ($currency) {
            ($deal_id) = await $self->{dbic}->query(
                q{SELECT * FROM transaction.add_new_deal($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)},
                $deal->deal_id, $self->{provider}, $deal->loginid, $deal->account_type, $deal->underlying_symbol,
                $deal->volume,  $deal->spread,     $deal->price,   $currency,           $deal->transaction_time
            )->single;
            $log->debugf(($deal_id ? "Deal [%s] saved" : "Deal [%s] already exist"), $deal->deal_id);
        } else {
            $log->errorf("quoted currency is undefined for %s", $deal->underlying_symbol);
        }
    } catch ($e) {
        # database error could return a Postgres::Error object.
        my $error_message = ref $e ? $e->message : $e;
        $log->warnf("exception thrown when saving deal into database. [%s]", $error_message);
        # TODO: reconnection is needed while waiting for the patch on Database::Async. Remove after patch is applied
        await $self->_reconnect();
    }

    return $deal->deal_id;
}

=head2 _check_pending_data_from_stream

Periodically checks for pending data from stream that has been idle for 5 minutes and try to process them.

=cut

async sub _check_pending_data_from_stream {
    my $self = shift;

    while (1) {
        # Check for idle pending data in the stream and try to reprocess it.
        my $pending = await $self->{redis}
            ->execute_command('XAUTOCLAIM', $self->{redis_stream}, $self->{redis_consumer_group}, 'IDLE', 300000, '0-0', 'COUNT', 100);
        my $processed_pending = await $self->_process_deals($pending->[1]);
        $log->debugf("%s pending messages processed", $processed_pending);

        await $self->_remove_pending();

        await $self->loop->delay_future(after => 60);
    }
}

=head2 _remove_pending

Remove pending messages from the stream when the message delivery count is more than 5.

These messages are permanently forgotten.

=cut

async sub _remove_pending {
    my $self = shift;

    # If pending message couldn't be process after 5 retry, we will remove it from the list
    my $pending_to_remove = await $self->{redis}->xpending($self->{redis_stream}, $self->{redis_consumer_group}, '-', '+', 10);
    foreach my $msg ($pending_to_remove->@*) {
        my $retry_count = $msg->[3];
        next if $retry_count <= 5;
        my $stream_id = $msg->[0];
        my $data      = await $self->{redis}->xrange($self->{redis_stream}, $stream_id, '+', 'COUNT', 1);
        my %payload   = $data->[0][1]->@*;
        $log->warnf("Remove %s from %s stream after %s failures to process attempts. payload [%s]",
            $stream_id, $self->{redis_stream}, $retry_count, \%payload);
        await $self->{redis}->xack($self->{redis_stream}, $self->{redis_consumer_group}, $stream_id);
    }
}

=head2 _reconnect

Reconnect to commission database.

=cut

async sub _reconnect {
    my $self = shift;

    # reconnect
    $self->remove_child($self->{dbic});

    my %parameters = (
        pool => {
            max => 4,
        },
    );

    if ($self->{db_uri}) {
        $parameters{uri} = $self->{db_uri};
    } else {
        $parameters{engine} = {service => $self->{db_service}};
        $parameters{type}   = 'postgresql';
    }

    $self->add_child($self->{dbic} = Database::Async->new(%parameters));

    stats_inc('bom.commission.deal_listener.db_reconnected.count');
}

1;
