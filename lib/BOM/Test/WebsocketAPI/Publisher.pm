package BOM::Test::WebsocketAPI::Publisher;

no indirect;

use strict;
use warnings;
use feature 'state';

=head1 NAME

BOM::Test::WebsocketAPI::Publisher - Responsible to publish values used for testing

=head1 SYNOPSIS

    $publisher = BOM::Test::WebsocketAPI::Publisher;

    $publisher->ticks(qw(R_100 R_50);

    diag explain $publisher->published;

=head1 DESCRIPTION

To publish data and access to the published data, be it to a database or Redis.
We can have only one instance of C<publisher> running, because the test database
will be shared between instances, and that can't work with expected values.

=cut

use parent qw(IO::Async::Notifier);

use Log::Any qw($log);
use List::Util qw(shuffle uniq reduce first);
use List::MoreUtils qw(first_index);
use JSON::MaybeUTF8 qw(:v1);
use Syntax::Keyword::Try;
use Test::More;
use curry;
use Try::Tiny;

use BOM::Test;
use Binary::API::Mapping::Response;
use BOM::Test::Data::Utility::FeedTestDatabase;
use Finance::Underlying;
use BOM::Test::WebsocketAPI::Redis qw/shared_redis ws_redis_master/;

our %handlers;

# Returns a singleton, there must be only one instance of publisher at all times
sub new {
    return our $ONE_TRUE_LOOP ||= shift->really_new(@_);
}

sub really_new {
    my $class = shift;

    BOM::Test::Data::Utility::FeedTestDatabase->import(qw(:init));
    return $class->SUPER::new(@_);
}

sub configure {
    my ($self, %args) = @_;
    for my $k (qw(ticks_history_count)) {
        $self->{$k} = delete $args{$k} if exists $args{$k};
    }
    return $self->next::method(%args);
}

=head2 ticks_history_count

Number of ticks history to generate

=cut

sub ticks_history_count { return shift->{ticks_history_count} }

=head2 published

Stores a list of expected responses (L<Binary::API::Mapping::Response>)
generated based on the published values to Redis or DB, per method.

=cut

sub published { return shift->{published} //= {} }

=head2 to_publish

Stores the event types to be published.

=cut

sub to_publish { return shift->{to_publish} //= {} }

=head2 ryu

Utility class used for timers, created on demand.

=cut

sub ryu {
    my $self = shift;

    return $self->{ryu} if exists $self->{ryu};

    $self->loop->add(my $ryu = Ryu::Async->new,);

    return $self->{ryu} = $ryu;
}

=head2 redis_timer

A timer which calls on_timer() every second, created on demand.

=cut

sub redis_timer {
    my $self = shift;

    return $self->{redis_timer} //= $self->start_publish;
}

=head2 publisher_state

Returns a hashref that keeps the publisher state, used to save information
across different calls to L<on_timer>.

=cut

sub publisher_state { return shift->{publisher_state} //= {} }

=head1 METHODS

=head2 handler

Defines a publish handler for a type of value to be published to Redis. The
publish handler will receive a request to be published every second.
The request is specified in the client side, where L<publish> is called.

Note that this is different from the function that makes those requests to
publish.

=cut

sub handler {
    my ($name, $code) = @_;

    return $handlers{$name} = $code;
}

=head2 website_status

Start publishing simulated website_status update events.
Returns the website_status message just published.

=over 4

=item * C<@symbols> - List of symbols

=back

=cut

sub website_status {
    my ($self, @requests) = @_;

    return undef unless @requests;

    push $self->to_publish->{website_status}->@*, @requests;

    $self->start_publish;

    return $self->published->{website_status};
}

=head2 tick

Start publishing simulated tick events for symbol(s).
Returns ticks already published.

=over 4

=item * C<@symbols> - List of symbols

=back

=cut

sub tick {
    my ($self, @requests) = @_;

    return undef unless @requests;

    push $self->to_publish->{tick}->@*, @requests;

    $self->start_publish;

    $self->generate_ticks_history(@requests);

    return $self->published->{tick};
}

=head2 transaction

Start publishing simulated transaction (and balance) events for an account ID.
Returns transactions already published.

Accepts a list of transaction information, which contains:

=over 4

=item * C<$client> - The L<BOM::User::Client> object to publish tx for

=item * C<$actions> - An array ref of action types to publish

=back

    $publisher->transaction(
        {
            client  => $client,
            actions => [qw(buy sell)],
        },
        ...
    )

=cut

sub transaction {
    my ($self, @requests) = @_;

    return undef unless @requests;

    push $self->to_publish->{transaction}->@*, @requests;

    $self->start_publish;

    $self->initial_balance(@requests);

    return $self->published->{transaction};
}

=head2 balance

Same as calling L<transaction>.

=cut

sub balance { return shift->transaction(@_) }

=head2 website_status handler

The code that handles publishing website_status into redis.

=cut

handler website_status => sub {
    my ($self, $params) = @_;

    my $ws_status = $self->fake_website_status($params);

    ws_redis_master->then(
        $self->$curry::weak(
            sub {
                my ($self, $redis) = @_;

                Future->wait_all(
                    $redis->set('NOTIFY::broadcast::is_on', $ws_status->{site_status} eq 'up'),
                    $redis->set('NOTIFY::broadcast::state', encode_json_utf8($ws_status)),
                    )->then(
                    sub {
                        $self->publish('NOTIFY::broadcast::channel', 'website_status', $ws_status, ws_redis_master);
                    });
            }))->retain;

    return undef;
};

=head2 tick handler

The code that handles publishing ticks into redis (and update ticks history).

=cut

handler tick => sub {
    my ($self, $symbol) = @_;
    my $tick = $self->update_ticks_history($self->fake_tick($symbol));
    return $self->publish("FEED::$symbol", tick => $tick) if $tick;
    return undef;
};

=head2 transaction handler

The code that handles publishing transaction and balance to Redis.

=cut

handler transaction => sub {
    my ($self,   $request) = @_;
    my ($client, $actions) = $request->@{qw(client actions)};

    $self->publisher_state->{contract_id}++;
    for my $action (@$actions) {
        my $transaction = $self->generate_transaction($client, $action);
        $self->publish('TXNUPDATE::transaction_' . $client->account->id, transaction => $transaction);

        # balance (each transaction update also updates the balance)
        $self->add_to_published(
            balance => {
                balance  => $transaction->{balance_after},
                currency => $client->currency,
                loginid  => $client->loginid,
            });
    }
    return undef;
};

=head2 on_timer

Called every second. Creates simulated events for everything currently in
C<to_publish>

=cut

sub on_timer {
    my ($self) = @_;

    for my $handler_name (keys %handlers) {
        next unless exists $self->to_publish->{$handler_name};
        for my $request ($self->to_publish->{$handler_name}->@*) {
            $handlers{$handler_name}->($self, $request);
        }
    }

    for my $proposal ($self->to_publish->{proposal}->@*) {
        #$proposal looks like [key, propsal_data ] here
        my $base_spot = $proposal->[1]->{spot};
        my $new_spot = sprintf('%.3f', $base_spot + rand(10));
        $proposal->[1]->{payout} = 0;    #$new_spot + 3;

        $proposal->[1]->{spot}      = $new_spot;
        $proposal->[1]->{spot_time} = time;
        $self->publish($proposal->[0], 'proposal', $proposal->[1]);
    }

    return undef;
}

=head2 publish

Publishes the given response to Redis, saving the expected response
in C<published>

=cut

sub publish {
    my ($self, $channel, $method, $payload, $redis_client) = @_;

    $redis_client //= shared_redis;

    $log->debugf('Publishing a %s, %s', $method, join ", ", map { $_ . ': ' . $payload->{$_} } sort keys $payload->%*);

    $redis_client->then(
        $self->$curry::weak(
            sub {
                my ($self, $redis) = @_;
                $redis->publish($channel => encode_json_utf8($payload))->on_done(
                    sub {
                        $self->add_to_published($method, $payload);
                    });
            }))->retain;

    return undef;
}

=head2 add_to_published

Pushes the expected response based on the payload that we published to Redis.

=cut

sub add_to_published {
    my ($self, $method, $payload) = @_;

    my $response = $self->published_to_response($method => $payload);

    push $self->published->{$method}->@*, $response;

    return undef;
}

# Global Variable used to map what is sent to what we expect when they differ.
my $published_to_response_mapping = {
    tick => {
        rename_fields => {
            spot => 'quote',
        }
    },
    transaction => {
        rename_fields => {
            action_type             => 'action',
            id                      => 'transaction_id',
            financial_market_bet_id => 'contract_id',
            balance_after           => 'balance',
            payment_remark          => 'longcode',
        },
    },
    proposal => {
        delete_fields => {
            theo_probability => 1,
            price_daemon_cmd => 1,
            rpc_time         => 1,
            payout           => 1
        },
    },
};

=head2 published_to_response

Map the published fields to the expected response from the API

=cut

sub published_to_response {
    my ($self, $method, $published, $options) = @_;

    my $frame = {
        echo_req => {
            # Don't know what to put in here
            $method => 'placeholder',
        },
        msg_type => $method,
        ($options // {})->%*,
    };

    for my $field (keys $published->%*) {
        my $mapping        = $published_to_response_mapping->{$method};
        my $response_field = $field;
        if ($mapping->{rename_fields}->{$field}) {
            $response_field = $published_to_response_mapping->{$method}->{rename_fields}->{$field};
        }
        if ($mapping->{delete_fields}->{$field}) {
            next;
        }
        $frame->{$method}->{$response_field} = $published->{$field};
    }

    return Binary::API::Mapping::Response->new($frame);
}

=head2 stop_publish

Stop publishing values to Redis

=cut

sub stop_publish {
    my ($self) = @_;

    return Future->done
        unless exists $self->{redis_timer}
        or $self->{redis_timer}->completed->is_ready;

    return $self->redis_timer->finish;
}

=head2 start_publish

Start publishing values to Redis

=cut

sub start_publish {
    my ($self) = @_;

    return $self->{redis_timer}
        if defined $self->{redis_timer}
        and not $self->{redis_timer}->completed->is_ready;

    $self->{redis_timer} = $self->ryu->timer(interval => 1)->each($self->$curry::weak(sub { shift->on_timer }));    ## no critic DeprecatedFeatures

    return $self->{redis_timer};
}

=head2 update_ticks_history

Update the history of ticks in database with newly generated ticks.
Returns the tick if it's new, C<undef> otherwise.

=cut

sub update_ticks_history {
    my ($self, $tick_to_publish) = @_;

    my $state  = $self->publisher_state;
    my $symbol = $tick_to_publish->{symbol};

    my $tick = {$tick_to_publish->%*, quote => $tick_to_publish->{spot}};

    my $current_history = $state->{ticks_history}->{$symbol};

    my @history_times  = ($current_history ? $current_history->body->times->@*  : ());
    my @history_prices = ($current_history ? $current_history->body->prices->@* : ());
    return if first { $_ eq $tick->{epoch} } @history_times;

    try {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => $symbol,
            $tick->%*,
        });
    }
    catch {
        $log->errorf('Unable to add history, (is the feed DB correctly initialized?) error: [%s]', $@);
    };

    my $history = {
        times  => [@history_times,  $tick->{epoch}],
        prices => [@history_prices, $tick->{quote}],
    };
    $state->{ticks_history}->{$symbol} = $self->published_to_response(
        history => $history,
        {echo_req => {ticks_history => $symbol}});

    my $published_history = $self->published->{history} //= [];
    my $published_index = first_index { $_->body->symbol eq $symbol } $published_history->@*;
    splice $published_history->@*, $published_index, 1 if $published_index > -1;
    push $published_history->@*, $state->{ticks_history}->{$symbol};

    return $tick_to_publish;
}

=head2 generate_ticks_history

Generate the initial ticks history in the database

=cut

sub generate_ticks_history {
    my ($self, @requests) = @_;

    for my $symbol (@requests) {
        next if exists $self->to_publish->{history}->{$symbol};
        $self->to_publish->{history}->{$symbol} = $symbol;
        my $now = time;
        for my $epoch (($now - $self->ticks_history_count) .. $now) {
            $self->update_ticks_history($self->fake_tick($symbol, {epoch => $epoch}));
        }
    }
    return undef;
}

=head2 initial_balance

Add the expected value for the initial balance

=cut

sub initial_balance {
    my ($self, @requests) = @_;

    my $balances = $self->publisher_state->{balances} //= {};

    for my $request (@requests) {
        my $client     = $request->{client};
        my $account_id = $client->account->id;

        unless (exists $balances->{$account_id}) {
            my $initial_balance = $client->account->balance;
            $balances->{$account_id} = $initial_balance;
            $self->add_to_published(
                balance => {
                    balance  => sprintf('%.2f', $initial_balance),
                    currency => $client->currency,
                    loginid  => $client->loginid,
                });
        }
    }
    return undef;
}

=head2 generate_transaction

Generates transaction payloads given an action type

=cut

sub generate_transaction {
    my ($self, $client, $action) = @_;

    my $balances = $self->publisher_state->{balances} //= {};
    my $signed_amount = 100 * rand() * ($action =~ /sell|deposit/ ? +1 : -1);
    $balances->{$client->account->id} += $signed_amount;
    return {
        action_type             => $action,
        id                      => ++$self->{transaction_id},
        financial_market_bet_id => $self->publisher_state->{contract_id},
        amount                  => sprintf('%.2f', $signed_amount),
        balance_after           => sprintf('%.2f', $balances->{$client->account->id}),
        payment_remark          => 'Description of the transaction',
    };
}

=head2 fake_tick

Returns a fake tick, accepts a hashref of optional override values.

=cut

sub fake_tick {
    my ($self, $symbol, $options) = @_;

    my $ul  = Finance::Underlying->by_symbol($symbol);
    my $bid = $ul->pipsized_value(10 + (100 * rand));
    my $ask = $ul->pipsized_value(10 + (100 * rand));
    ($ask, $bid) = ($bid, $ask) unless $bid <= $ask;
    return {
        symbol => $symbol,
        epoch  => time,
        bid    => $bid,
        ask    => $ask,
        spot   => $ul->pipsized_value(($bid + $ask) / 2),
        ($options // {})->%*,
    };
}

=head2 proposal

Generate proposal contracts from the supplied proposal requests

Takes the following arguments as named parameters

=over 4

=item C<$self> 
=item C<$proposal_requests> an ArrayRef of proposal subscription requests that you want contract data for. 

=back

Returns the published proposals

=cut

sub proposal {
    my ($self, @proposal_requests) = @_;
    return undef unless @proposal_requests;

    my @fake_contracts = map { $self->fake_proposal_contracts($_) } @proposal_requests;
    push $self->to_publish->{proposal}->@*, @fake_contracts;

    $self->redis_timer;

    return $self->published->{proposal};
}

=head2 fake_proposal_contracts

Creates contracts that can pushed into redis for proposals, it uses the data from the proposal request
to create the appropriate data. 
Takes the following arguments as named parameters

=over 4

=item C<proposal>  string  either 'price' or 'buy'

=back

Returns an Arrayref 
    
    [key, value]

=cut

sub fake_proposal_contracts {
    my ($self, $proposal_request) = @_;
    my $time = time();
    my $product_type = $proposal_request->{product_type} // 'basic';
    my $key =
          'PRICER_KEYS::["amount","1000","basis","payout","contract_type","'
        . $proposal_request->{contract_type}
        . '","country_code","aq","currency","'
        . $proposal_request->{currency}
        . '","duration","'
        . $proposal_request->{duration}
        . '","duration_unit","'
        . $proposal_request->{duration_unit}
        . '","landing_company",null,"price_daemon_cmd","price","product_type","'
        . $product_type
        . '","proposal","1","skips_price_validation","1","subscribe","1","symbol","'
        . $proposal_request->{symbol} . '"]';
    my $value = {
        "ask_price"        => "537.10",
        "longcode"         => "longcode",
        "date_start"       => $proposal_request->{date_start} // $time,
        "spot"             => "78.942",
        "payout"           => "1000",
        "spot_time"        => $time,
        "display_value"    => "537.10",
        "theo_probability" => 0.502096693150372,
        "price_daemon_cmd" => "price"
    };

    return ([$key, $value]);
}

=over 4

=head2 fake_website_status

Creates C<website_status> messages that can be pushed into redis.
Takes the following arguments:

=over 4

=item C<params> a hash ref contining website status attributes.

=back

Returns a hashref containing C<site_status> and C<passthrough>
    

=cut

sub fake_website_status {
    my ($self, $params) = @_;

    return {
        site_status => $params->{site_status} // 'up',
        # a unique message is added, expecting to be delivered to website_status subscribers (needed for sanity checks).
        passthrough => {
            test_publisher_message => 'message #' . ++$self->{ws_counter},
        },
    };
}

1;
