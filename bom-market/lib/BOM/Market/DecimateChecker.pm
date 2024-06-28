package BOM::Market::DecimateChecker;

use strict;
use warnings;

=head1 NAME

BOM::Market::DecimateChecker

=head1 SYNOPSIS

    use BOM::Market::DecimateChecker;
    use Finance::Underlying;
    my %ul      = (symbols => {$symbol => Finance::Underlying->by_symbol('frxUSDJPY')});
    my $checker = BOM::Market::DecimateChecker->new(%ul);

=head1 DESCRIPTION

This modules checks the published ticks between Feed Redis and Feed Database

=head1 DATA

=over 4

=item Feed DB

Retrives the ticks with C<ticks_in_between_start_end> function from feed db

=item Redis Replicated

It will read the ticks in C<DECIMATE_$symbol_32m_FULL> to compare with the ticks in the database

=back

=head2 METHODS

=cut

use parent 'IO::Async::Notifier';

use Future::AsyncAwait;
use Net::Async::Redis;
use Postgres::FeedDB::Spot::DatabaseAPI;
use BOM::MarketData qw(create_underlying_db);
use YAML::XS        qw(LoadFile);
use Log::Any        qw($log);
use Sereal::Decoder;
use Time::HiRes                qw(gettimeofday);
use DataDog::DogStatsd::Helper qw(stats_gauge);
use Array::Utils               qw(:all);
use List::Util                 qw(max);
use Finance::Underlying;

sub redis     { shift->{redis} }
sub terminate { shift->{terminate} }
sub markets   { shift->{markets} }
sub symbols   { shift->{symbols} }
sub decoder   { shift->{decoder} //= Sereal::Decoder->new }
sub executing { shift->{executing} }

=head2 log_limit

Number of times we log missing ticks before changing start time

=cut

sub log_limit { 5 }

=head2 retention_interval

The amount of time to look back for checking tick, 30 minutes and 30 seconds
This is 30 seconds less than L<BOM::Market::DataDecimate::_raw_retention_interval>

=cut

sub retention_interval { 1830 }

=head2 tick_miss_history

History of missed ticks that is used to update start time.
Values for each key consists of C<epoch> and C<times>

=cut

sub tick_miss_history { shift->{tick_miss_history} }

sub new {
    my ($class, %args) = @_;
    $args{markets}  //= ['forex', 'synthetic_index'];
    $args{interval} //= "32m";
    $args{tick_miss_history} = {};
    my $self = bless \%args, $class;
    return $self;
}

sub stop {
    my $self = shift;
    return $self->{stop} //= $self->loop->new_future->set_label('DecimateChecker stopping')->on_ready(sub { kill 9, $$; });
}

sub _add_to_loop {
    my ($self) = @_;
    $self->{terminate} = 0;

    my $config = LoadFile('/etc/rmg/redis-feed.yml')->{'replica-read'}
        or die $log->fatal("Couldn't load config (replica-read) file /etc/rmg/redis-feed.yml");
    my $redis = Net::Async::Redis->new(
        uri  => "redis://$config->{host}:$config->{port}",
        auth => $config->{password});

    $self->add_child($redis);
    $self->{redis} = $redis;
}

async sub get_config {
    my ($self) = @_;
    my @symbols = ();

    for my $market ($self->markets->@*) {
        my $sym;
        if ($market eq 'forex') {
            $sym = [create_underlying_db->symbols_for_intraday_fx(1)];
        } elsif ($market eq 'synthetic_index') {
            $sym = [
                create_underlying_db->get_symbols_for(
                    market            => 'synthetic_index',
                    contract_category => 'lookback'
                )];
        } else {
            $log->warnf('Unknown market: %s', $market);
        }
        push @symbols, @$sym if $sym;
    }
    $self->{symbols} = {map { $_ => Finance::Underlying->by_symbol($_) } @symbols};
}

=head2 run()

Run the decimate checker. Only public method in this class.
Every few seconds calls C<check_decimate_sync> for checking ticks in Redis and Database

=cut

async sub run {
    my ($self) = @_;

    $self->loop->watch_signal(
        'TERM',
        sub {
            $self->{terminate} = 1;
            $self->stop->done('Terminate', 'SIGNAL') if (!$self->stop->is_ready && !$self->executing);
        });

    await $self->get_config;

    while (!$self->stop->is_ready) {
        # Enable Decimate checker.
        await $self->check_decimate_sync;

        $self->stop->done('Terminate', 'SIGNAL') if (!$self->stop->is_ready && $self->terminate);
        # This will be the interval of this check, i.e how often we want to run it.
        await $self->loop->delay_future(after => 2);
    }
}

=head2 check_decimate_sync()

Checks periodically for mis-matches between Redis and Database.
In case there's any discrepancies it will log it for C<log_limit> times

=cut

async sub check_decimate_sync {
    my ($self) = @_;

    $self->{executing} = 1;
    await $self->redis->connected;
    my $end         = [gettimeofday]->[0];
    my $last_period = $end - $self->retention_interval;
    my $interval    = $self->{interval};

    for my $symbol (keys $self->symbols->%*) {
        my $last_miss_epoch = $self->tick_miss_history->{$symbol}{epoch} // 0;
        my $start           = max($last_period, $last_miss_epoch);

        my $redis_ticks =
            [map { $self->decoder->decode($_) }
                @{await $self->redis->zrevrangebyscore("DECIMATE_" . $symbol . "_" . $interval . "_FULL", $end, $start)}];
        my $feed_api = Postgres::FeedDB::Spot::DatabaseAPI->new({
            underlying => $symbol,
            dbic       => Postgres::FeedDB::write_dbic,
        });
        my $db_ticks = $feed_api->ticks_start_end({
            start_time => $start,
            end_time   => $end,
        });

        my ($redis_epoch, $redis_all, $redis_recent_epoch) = process_tick_range($redis_ticks, 'redis');
        my ($db_epoch,    $db_all,    $db_recent_epoch)    = process_tick_range($db_ticks,    'db');

        my $epoch_diff = $db_recent_epoch - $redis_recent_epoch;
        my $count_diff = scalar @$db_epoch - scalar @$redis_epoch;

        _send_stats($symbol, $epoch_diff, $count_diff);
        $log->debugf('(%s - %s) Symbol: %s | epoch_diff: %s | count_diff: %s', $start, $end, $symbol, $epoch_diff, $count_diff);

        # Note that we will not be alerting if last epoch is zero. because this has been done elsewhere.
        # At this point we just want to make sure that both Redis and Database are matching.

        my @different_epochs = array_diff(@$db_epoch, @$redis_epoch);
        my $have_more_ticks  = $count_diff >= 0 ? $db_all : $redis_all;
        my $diff             = [map { $have_more_ticks->{$_} } @different_epochs];

        # Since we count for replication and network Redis delays
        # Threshold set to be more than 1 tick delayed from current time selection.
        next unless abs($count_diff) > 1;

        $log->warnf('Missing ticks detected in Redis for %s (%s): From: %s | To: %s | Ticks: %s', $symbol, $interval, $start, $end, $diff);

        if (++$self->tick_miss_history->{$symbol}{times} >= $self->log_limit) {
            my $new_start = max @$db_epoch;
            $self->tick_miss_history->{$symbol}{epoch} = $new_start;
            $self->tick_miss_history->{$symbol}{times} = 0;
            $log->warnf('Stopping logs for "Missing ticks detected in Redis" until the end of this period: Starting tick check for %s from %s',
                $symbol, $new_start);
        }
    }

    $self->{executing} = 0;
}

sub _send_stats {
    my ($symbol, $epoch_diff, $count_diff) = @_;
    stats_gauge('tick_decimator.redis_db_epoch_diff', $epoch_diff, {tags => ['symbol:' . $symbol]});
    stats_gauge('tick_decimator.redis_db_count_diff', $count_diff, {tags => ['symbol:' . $symbol]});
}

=head2 process_tick_range

    process_tick_range($ticks, $source)

Accepts and array reference containing list of ticks. Those ticks could be coming from a Postgres Database source or Redis source.
it rearrangs ticks into an array containing a list of epoch only, and Hash where epoch is key and tick is value. and the most recent epoch in ticks.

=cut

sub process_tick_range {
    my ($ticks, $source) = @_;

    my (@epoch_array, $all, $recent_epoch);
    for my $tick (@$ticks) {
        my $epoch = $tick->{epoch};
        $recent_epoch //= $epoch;
        push @epoch_array, $epoch;
        $tick->{source} = $source;
        $tick           = {map { $_ => $tick->{$_} } qw\symbol epoch quote source\};
        $all->{$epoch}  = $tick;
    }

    $recent_epoch //= 0;
    return (\@epoch_array, $all, $recent_epoch);
}

1;

