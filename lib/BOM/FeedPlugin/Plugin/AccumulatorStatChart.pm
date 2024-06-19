package BOM::FeedPlugin::Plugin::AccumulatorStatChart;

use strict;
use warnings;
use feature 'state';

use Moo;
use Scalar::Util  qw( blessed );
use YAML::XS      qw(LoadFile);
use JSON::MaybeXS qw(decode_json encode_json);
use Time::HiRes;
use DataDog::DogStatsd::Helper qw(stats_inc stats_timing);

use BOM::Config::Redis;
use BOM::Config;
use Postgres::FeedDB;
use Postgres::FeedDB::Spot::DatabaseAPI;

=head1 NAME

BOM::FeedPlugin::Plugin::AccumulatorStatChart

=head1 SYNOPSIS

use BOM::FeedPlugin::Plugin::AccumulatorStatChart;

=head1 DESCRIPTION

This package is used as a plugin by L<BOM::FeedPlugin::Client> where it will be called if it was added to the array of plugins in Client.
On each tick it invokes L<accumulator_stat_chart_generator> and updates the stat chart for accumulator contract type, which is a list that 
reflects the number of ticks stayed in between barriers for each symbol on a specific growth rate.
Upon system restart it checks the ticks during the downtime and processes them. 

=cut

use constant SEPARATOR                => '::';                                                             # How to join strings together
use constant HASH_NAME                => join(SEPARATOR, 'accumulator', 'previous_tick_barrier_status');
use constant STAT_HISTORY_ACCUMULATOR => 100;    # Max. size of redis list containing tick barrier status

my $default_tick_size_barrier = LoadFile('/home/git/regentmarkets/bom-config/share/default_tick_size_barrier_accumulator.yml');

=head2 redis_read

redis read attribute for local replica

=cut

has redis_read => (
    is      => 'ro',
    builder => '_build_redis_read',
);

=head2 redis_write

redis write attribute for the master redis

=cut

has redis_write => (
    is      => 'ro',
    builder => '_build_redis_write',
);

=head2 last_stored_tick_barrier_status

last_stored_tick_barrier_status attribute

=cut

has last_stored_tick_barrier_status => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_last_stored_tick_barrier_status',
);

=head2 _build_redis_read

building redis read attribute for local replica

=cut

sub _build_redis_read {

    return BOM::Config::Redis::redis_replicated_read();
}

=head2 _build_redis_write

build redis write attribute for master redis

=cut

sub _build_redis_write {

    return BOM::Config::Redis::redis_replicated_write();
}

=head2 _build_last_stored_tick_barrier_status

Here we retrieve the last stored status of a symbol's tick. This is useful when
the service is restarted and these historical data can be used to process missed ticks. 

=cut

sub _build_last_stored_tick_barrier_status {
    my $self = shift;

    my $hash_data       = {};
    my $stored_barriers = $self->redis_read->execute('hgetall', HASH_NAME);

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
            $self->accumulator_stat_chart_generator($tick, $growth_rate, $tick_size_barrier);
        }
        delete $self->last_stored_tick_barrier_status->{$hash_key};
    } elsif ($self->last_stored_tick_barrier_status->{$hash_key}->{tick_epoch} == $tick->{epoch}) {
        # This case happens when the last proccesed tick would be equal to the current tick.
        # This can happen when the service is restarted but the next tick has not been recieved yet.
        delete $self->last_stored_tick_barrier_status->{$hash_key};
    } else {
        # This case happens when the number of missed ticks are more than the given threshold.
        # In this case we delete the cache and process the current tick.
        $self->delete_redis_keys($hash_key);
        delete $self->last_stored_tick_barrier_status->{$hash_key};
    }
    return;
}

=head2 delete_redis_keys

This function deletes accumulator related redis keys.

=cut

sub delete_redis_keys {
    my ($self, $hash_key) = @_;

    my ($symbol, $growth_rate) = split(SEPARATOR, $hash_key);
    my $stat_key = join(SEPARATOR, 'accumulator', 'stat_history', $symbol, $growth_rate);

    $self->redis_write->execute('multi');
    $self->redis_write->execute('hdel', HASH_NAME, $hash_key);
    $self->redis_write->execute('del', $stat_key);
    $self->redis_write->execute('exec');

    return;
}

=head2 get_barriers

calculate high and low barriers for accumulator contract category.

=cut

sub get_barriers {
    my ($spot, $tick_size_barrier) = @_;

    return {
        high_barrier => $spot * (1 + $tick_size_barrier),
        low_barrier  => $spot * (1 - $tick_size_barrier)};
}

=head2 accumulator_stat_chart_generator

Generally this function populates an array which contains a number of historical values representing 
the ticks between two barrier crosssings.

=cut

sub accumulator_stat_chart_generator {

    my ($self, $tick, $growth_rate, $tick_size_barrier) = @_;

    state $cached_history = {};
    my ($previous_tick_barrier_status, $counter, $stat_chart_len);
    my $symbol       = $tick->{symbol};
    my $current_spot = $tick->{quote};
    my $stat_key     = join(SEPARATOR, 'accumulator', 'stat_history', $symbol, $growth_rate);
    my $hash_key     = join(SEPARATOR, $symbol, $growth_rate);
    my $barriers     = get_barriers($current_spot, $tick_size_barrier);

    my $current_tick_barrier_status = {
        high_barrier => $barriers->{high_barrier},
        low_barrier  => $barriers->{low_barrier},
        tick_epoch   => $tick->{epoch}};

    if (exists $cached_history->{$hash_key}) {
        $previous_tick_barrier_status = $cached_history->{$hash_key}->{previous_tick_barrier_status};
        $counter                      = $cached_history->{$hash_key}->{counter};
        $stat_chart_len               = $cached_history->{$hash_key}->{stat_chart_len};
    } else {
        $previous_tick_barrier_status = $self->redis_read->execute('hget', HASH_NAME, $hash_key);
        if ($previous_tick_barrier_status) {
            $counter                      = $self->redis_read->execute('lindex', $stat_key, '-1');
            $stat_chart_len               = $self->redis_read->execute('llen',   $stat_key);
            $previous_tick_barrier_status = decode_json($previous_tick_barrier_status);
        }
    }

    unless ($previous_tick_barrier_status and $stat_chart_len and defined $counter) {
        $self->redis_write->execute('multi');
        $self->redis_write->execute('rpush', $stat_key, 0);
        $self->redis_write->execute('hset', HASH_NAME, $hash_key, encode_json($current_tick_barrier_status));
        $self->redis_write->execute('exec');

        $cached_history->{$hash_key} = {
            previous_tick_barrier_status => $current_tick_barrier_status,
            counter                      => 0,
            stat_chart_len               => 1
        };
        return;
    }

    if ($current_spot >= $previous_tick_barrier_status->{high_barrier} or $current_spot <= $previous_tick_barrier_status->{low_barrier}) {
        if ($stat_chart_len >= STAT_HISTORY_ACCUMULATOR) {
            $self->redis_write->execute('multi');
            $self->redis_write->execute('lpop',  $stat_key);
            $self->redis_write->execute('rpush', $stat_key, 0);
            $self->redis_write->execute('hset',  HASH_NAME, $hash_key, encode_json($current_tick_barrier_status));
            $self->redis_write->execute('exec');
        } else {
            $self->redis_write->execute('multi');
            $self->redis_write->execute('rpush', $stat_key, 0);
            $self->redis_write->execute('hset', HASH_NAME, $hash_key, encode_json($current_tick_barrier_status));
            $self->redis_write->execute('exec');
            $stat_chart_len += 1;
        }

        $cached_history->{$hash_key} = {
            previous_tick_barrier_status => $current_tick_barrier_status,
            counter                      => 0,
            stat_chart_len               => $stat_chart_len
        };
    } else {
        $self->redis_write->execute('multi');
        $self->redis_write->execute('lset', $stat_key, '-1',      $counter + 1);
        $self->redis_write->execute('hset', HASH_NAME, $hash_key, encode_json($current_tick_barrier_status));
        $self->redis_write->execute('exec');

        $cached_history->{$hash_key} = {
            previous_tick_barrier_status => $current_tick_barrier_status,
            counter                      => $counter + 1,
            stat_chart_len               => $stat_chart_len
        };
    }
    return;
}

=head2 on_tick

The main method which it will receive a tick and then invoke I<accumulator_stat_chart_generator> with the latest tick, and updates DD stats.

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
            $self->accumulator_stat_chart_generator($tick, $growth_rate, $tick_size_barrier);
        }
    }

    # update statistics about number of processed ticks (once in 10 ticks)
    my $basename = 'feed.client.plugin.accumulator_stat_chart_generator';
    my $latency  = $ts - $tick->{epoch};
    my $tags     = {tags => ['seconds:' . int($latency)]};

    stats_timing("$basename.latency", 1000 * $latency, $tags);

    return;
}

1;
