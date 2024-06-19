use strict;
use warnings;

use Test::More;
use Data::Dumper;
use Test::MockObject;
use Test::MockModule;
use Log::Any::Test;
use Log::Any qw($log);
require Log::Any::Adapter;
Log::Any::Adapter->import(qw(Stderr), log_level => 'info');

use Future;
use Future::AsyncAwait;
use Sereal::Encoder;
use BOM::Market::DecimateChecker;
use Finance::Underlying;

my $no_of_ticks = 10;
my $epoch       = time;
my $symbol      = 'R_100';
my $encoder     = Sereal::Encoder->new();

sub redis_tick {
    my $step = shift;
    return sub {
        my $tick = $encoder->encode({
            symbol => $symbol,
            count  => 1,
            epoch  => $epoch + $step * 2,
            bid    => 100 + $step,
            ask    => 102 + $step,
            quote  => 101 + $step,
        });
        $step += 1;
        return $tick;
    }
}

sub db_tick {
    my $step = shift;
    return sub {
        my $tick = Postgres::FeedDB::Spot::Tick->new({
            symbol => $symbol,
            epoch  => $epoch + $step * 2,
            bid    => 100 + $step,
            ask    => 102 + $step,
            quote  => 101 + $step,
        });
        $step += 1;
        return $tick;
    }
}

# Init Redis and db
my $next_db_tick    = db_tick(-$no_of_ticks);
my $next_redis_tick = redis_tick(-$no_of_ticks);

# Filling older ticks. Order must be descending
my $redis_ticks = [reverse map { $next_redis_tick->() } (1 .. $no_of_ticks)];
my @db_ticks    = reverse map { $next_db_tick->() } (1 .. $no_of_ticks);

my %ul      = (symbols => {$symbol => Finance::Underlying->by_symbol($symbol)});
my $checker = BOM::Market::DecimateChecker->new(%ul);

# Mockings
my $mocked_redis = Test::MockObject->new;
$mocked_redis->mock('connected',        sub { Future->done });
$mocked_redis->mock('zrevrangebyscore', sub { Future->done($redis_ticks) });

my $mocked_decimate = Test::MockModule->new('BOM::Market::DecimateChecker');
$mocked_decimate->mock('redis', sub { $mocked_redis });

my $mocked_underlyings = Test::MockModule->new('Postgres::FeedDB::Spot::DatabaseAPI');
$mocked_underlyings->mock('ticks_start_end', sub { \@db_ticks });

subtest "Checking Redis and database synchronization" => sub {
    note 'Redis and database are in sync';
    $mocked_decimate->mock(
        '_send_stats',
        sub {
            my ($s, $epoch_diff, $count_diff) = @_;
            is $s,          $symbol, 'Comparing designated symbol';
            is $epoch_diff, 0,       'There is no diff in epochs';
            is $count_diff, 0,       'There is no diff in counts';
        });
    $checker->check_decimate_sync->get;

    note 'Redis falls one tick behind database';
    unshift @db_ticks, $next_db_tick->();
    $mocked_decimate->mock(
        '_send_stats',
        sub {
            my ($s, $epoch_diff, $count_diff) = @_;
            is $s,          $symbol, 'Comparing designated symbol';
            is $epoch_diff, 2,       'Redis is two seconds behind database';
            is $count_diff, 1,       'There is one tick missing in Redis';
        });
    $checker->check_decimate_sync->get;
    $log->does_not_contain_ok(qr/Extra Ticks/, 'If there is only one tick missing wait for sync');

    note 'Redis is more than one tick behind database';
    unshift @db_ticks, $next_db_tick->();
    $mocked_decimate->mock(
        '_send_stats',
        sub {
            my ($s, $epoch_diff, $count_diff) = @_;
            is $s,          $symbol, 'Comparing designated symbol';
            is $epoch_diff, 4,       'Redis is four seconds behind database';
            is $count_diff, 2,       'There are two tick missing in Redis';
        });
    $checker->check_decimate_sync->get;

    my @errors = grep { $_->{level} eq 'warning' } $log->msgs->@*;
    like $errors[0]->{message}, qr/Missing ticks detected in Redis for $symbol/, '"Extra ticks" message should be logged';
    is $checker->tick_miss_history->{$symbol}{times}, 1,     'We logged extra tick message once';
    is $checker->tick_miss_history->{$symbol}{epoch}, undef, 'As long as we have not reach the limit, symbol epoch for missed tich is not set';

    note 'Until we reach the log limit we must report the missing ticks';
    $mocked_decimate->mock('_send_stats', sub { });
    my $limit = $checker->log_limit;
    for (1 .. $limit - 2) {
        unshift @db_ticks, $next_db_tick->();
        $checker->check_decimate_sync->get;
    }
    is $checker->tick_miss_history->{$symbol}{times}, $limit - 1, "Extra tick error reported $limit times";

    note 'After we reach limit, reset start time to latest mismatched epoch';
    $log->clear();
    unshift @db_ticks, $next_db_tick->();
    $checker->check_decimate_sync->get;
    is $checker->tick_miss_history->{$symbol}{times}, 0, 'Symbol log counter must be reset to zero';
    my $new_start = $checker->tick_miss_history->{$symbol}{epoch};
    is $new_start, $db_ticks[0]->{epoch}, 'Symbol latest missing tick epoch must be set to the lastest tick in db';
    $log->contains_ok(
        qr/Stopping logs for "Missing ticks detected in Redis" until the end of this period: Starting tick check for $symbol from $new_start/,
        'Inform that start time for checking ticks mismatch for this symbol changed until next period');
};

done_testing();
