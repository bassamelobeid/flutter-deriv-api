package BOM::FeedPlugin::Plugin::AccumulatorExpiry;

use strict;
use warnings;

use Moo;
use Scalar::Util  qw( blessed );
use YAML::XS      qw(LoadFile);
use JSON::MaybeXS qw(decode_json);
use Time::HiRes;
use DataDog::DogStatsd::Helper qw(stats_inc stats_timing);

use ExpiryQueue;
use BOM::Config::Redis;
use BOM::Config;
use Postgres::FeedDB;
use Postgres::FeedDB::Spot::DatabaseAPI;

=head1 NAME

BOM::FeedPlugin::Plugin::AccumulatorExpiry

=head1 SYNOPSIS

use BOM::FeedPlugin::Plugin::AccumulatorExpiry;

=head1 DESCRIPTION

This package is used as a plugin by L<BOM::FeedPlugin::Client> where it will be called if it was added to the array of plugins in Client.
On each tick it invokes L<accumulator_expiry> and checks the expiry condition based on barrier crossing. 
Upon system restart it checks the ticks during the downtime and processes them. 

=cut

use constant SEPARATOR => '::';                                                                    # How to join strings together
use constant HASH_NAME => join(SEPARATOR, 'accumulator', 'previous_tick_barrier_status_expiry');

my $default_tick_size_barrier = LoadFile('/home/git/regentmarkets/bom-config/share/default_tick_size_barrier_accumulator.yml');

=head2 redis

redis expiry attribute

=cut

has redis => (
    is      => 'ro',
    builder => '_build_redis',
);

=head2 expiryq

expiryq attribute

=cut

has expiryq => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_expiryq',
);

=head2 last_stored_tick_barrier_status

last_stored_tick_barrier_status attribute

=cut

has last_stored_tick_barrier_status => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_last_stored_tick_barrier_status',
);

=head2 _build_redis

build redis expiry attribute

=cut

sub _build_redis {

    return BOM::Config::Redis::redis_expiryq_write();
}

=head2 _build_expiryq

build expiryq attribute

=cut

sub _build_expiryq {
    my $self = shift;

    return ExpiryQueue->new(
        redis => $self->redis,
    );
}

=head2 _build_last_stored_tick_barrier_status

Here we retrieve the last stored status of a symbol's tick. This is useful when
the service is restarted and these historical data can be used to process missed ticks. 

=cut

sub _build_last_stored_tick_barrier_status {
    my $self = shift;

    my $hash_data       = {};
    my $stored_barriers = $self->redis->execute('hgetall', HASH_NAME);

    return $hash_data unless @$stored_barriers;

    for (my $i = 0; $i < @$stored_barriers - 1; $i += 2) {
        $hash_data->{$stored_barriers->[$i]} = decode_json($stored_barriers->[$i + 1]);
    }

    return $hash_data;
}

=head2 _missed_ticks_on_restart

Upon system restart we miss ticks between the stop and start time of the service. 
This function retrieves those ticks from DB so that they can be processed. 

=cut

sub _missed_ticks_on_restart {

    my ($self, $tick, $symbol, $hash_key) = @_;

    my $from = $self->last_stored_tick_barrier_status->{$hash_key}->{tick_epoch} + 1;
    my $to   = $tick->{epoch};

    return [$tick] if $from == $to;
    # here we put a limit on on how many missed ticks the service's going to process.
    return if $from > $to or (($to - $from) > 30);

    my $feed_api = Postgres::FeedDB::Spot::DatabaseAPI->new({
        underlying => $symbol,
        dbic       => Postgres::FeedDB::read_dbic,
    });
    my $ticks = $feed_api->ticks_start_end({
        start_time => $from,
        end_time   => $to,
    });

    return unless ($ticks and @$ticks);

    # We reverse to get the ticks from the oldest to the newest.
    $ticks = [reverse @$ticks];

    return $ticks;

}

=head2 _process_missed_ticks_on_restart

This function processes ticks which are missed during the restart of the service.

=cut

sub _process_missed_ticks_on_restart {
    my ($self, $tick, $symbol, $growth_rate, $tick_size_barrier, $hash_key) = @_;

    my $missed_ticks = $self->_missed_ticks_on_restart($tick, $symbol, $hash_key);
    if ($missed_ticks) {
        # If there would be any missed ticks, they are processed here
        foreach my $tick (@$missed_ticks) {
            $self->expiryq->accumulator_expiry($tick, HASH_NAME, $growth_rate, $tick_size_barrier);
        }
        delete $self->last_stored_tick_barrier_status->{$hash_key};
    } elsif ($self->last_stored_tick_barrier_status->{$hash_key}->{tick_epoch} == $tick->{epoch}) {
        # This case happens when the last proccesed tick would be equal to the current tick.
        # This can happen when the service is restarted but the next tick has not been recieved yet.
        delete $self->last_stored_tick_barrier_status->{$hash_key};
    } else {
        # This case happens when the number of missed ticks are more than the given threshold.
        # In this case we delete the cache and process the current tick.
        $self->redis->execute('hdel', HASH_NAME, $hash_key);
        $self->expiryq->accumulator_expiry($tick, HASH_NAME, $growth_rate, $tick_size_barrier);
        delete $self->last_stored_tick_barrier_status->{$hash_key};
    }
    return;
}

=head2 on_tick

The main method which it will receive a tick and then invoke I<accumulator_expiry> with the latest tick, and updates DD stats.

=cut

sub on_tick {
    my ($self, $tick) = @_;

    # At this moment, this tick should be available to the clients that are using it.
    # Log the latency here.
    my $ts = Time::HiRes::time;

    # Turn object into simple hash
    $tick = $tick->as_hash if (blessed $tick);

    # Only process those symbols offered for accumulator
    return unless (exists $default_tick_size_barrier->{$tick->{symbol}});

    my $symbol = $tick->{symbol};

    foreach my $growth_rate (keys %{$default_tick_size_barrier->{$symbol}}) {
        my $hash_key          = join(SEPARATOR, $symbol, $growth_rate);
        my $tick_size_barrier = $default_tick_size_barrier->{$symbol}->{$growth_rate};
        if (%{$self->last_stored_tick_barrier_status} and $self->last_stored_tick_barrier_status->{$hash_key}) {
            $self->_process_missed_ticks_on_restart($tick, $symbol, $growth_rate, $tick_size_barrier, $hash_key);
        } else {
            $self->expiryq->accumulator_expiry($tick, HASH_NAME, $growth_rate, $tick_size_barrier);
        }
    }

    # update statistics about number of processed ticks (once in 10 ticks)
    my $basename = 'feed.client.plugin.accumulator_expiry';
    my $latency  = $ts - $tick->{epoch};
    my $tags     = {tags => ['seconds:' . int($latency)]};

    stats_timing("$basename.latency", 1000 * $latency, $tags);

    return;
}

1;
