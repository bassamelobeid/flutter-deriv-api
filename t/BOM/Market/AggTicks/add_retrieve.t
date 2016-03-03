use strict;
use warnings;

use Test::Most;
use Test::FailWarnings;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use BOM::Test::Data::Utility::UnitTestRedis;

use BOM::Market::Underlying;
use BOM::Test::Data::Utility::FeedTestDatabase qw( :init );
use BOM::Platform::Runtime;

use BOM::Market::AggTicks;

BOM::Test::Data::Utility::FeedTestDatabase::setup_ticks('frxUSDJPY/14-Mar-12.dump');

my $retention     = 120;
my $agg           = 4;
my $fake_symbol   = 'fake_testing_symbol';
my $ersatz_symbol = 'other_fake_testing_symbol';
my $real_symbol   = 'frxUSDJPY';
my $namespace     = 'unit_test_agg' . $$;

my $fake_underlying   = BOM::Market::Underlying->new($fake_symbol);
my $ersatz_underlying = BOM::Market::Underlying->new($ersatz_symbol);
my $real_underlying   = BOM::Market::Underlying->new($real_symbol);

my $at = BOM::Market::AggTicks->new({
    namespace              => $namespace,
    agg_interval           => $agg,
    returns_interval       => $agg,
    agg_retention_interval => $retention
});
my $big_at = BOM::Market::AggTicks->new({
    namespace              => $namespace,
    agg_interval           => 600,
    returns_interval       => 600,
    agg_retention_interval => 86399,
});

my $now = time;
$now = $now - ($now % $at->agg_interval->seconds);
my $count = 10 + rand(5);    # Randomized but constant for reasonable testing.

foreach my $i (1 .. 6) {
    $at->add({
        symbol => $fake_symbol,
        epoch  => $now - $i * $agg,
        quote  => $i,
    });
    $at->add({
        symbol => $ersatz_symbol,
        epoch  => $now - $i * $agg,
        quote  => $i,
    });
}

my %intervals = (
    '6s'  => 1,
    '9s'  => 2,
    '15s' => 3,
    '30m' => 6,
    '1d'  => 6,
);

my $similar_at = BOM::Market::AggTicks->new({
    namespace          => $namespace,
    agg_interval       => $agg,
    retention_interval => $retention
});

foreach my $ticker ($at, $similar_at) {
    $ticker->aggregate_for({
        underlying   => $fake_underlying,
        ending_epoch => $now
    });
}

foreach my $interval (keys %intervals) {
    my $ti = Time::Duration::Concise::Localize->new(interval => $interval);
    my @same_object = @{
        $at->retrieve({
                underlying   => $fake_underlying,
                tick_count   => $intervals{$interval},
                ending_epoch => $now,
            })};
    my @similar_object = @{
        $similar_at->retrieve({
                underlying   => $fake_underlying,
                tick_count   => $intervals{$interval},
                ending_epoch => $now,
                fill_cache   => 0,
            })};
    is(scalar @same_object, $intervals{$interval}, 'Matching number of ticks for interval ' . $ti->as_concise_string);
    is(scalar @similar_object,
        $intervals{$interval}, 'Matching number of ticks for interval ' . $ti->as_concise_string . ' on similarly configured object');

    foreach my $result (@same_object) {
        my $epoch          = $result->{epoch};
        my $similar_result = shift @similar_object;
        is_deeply($similar_result, $result, 'Our two objects are in sync at ' . $epoch);
    }
    is(scalar @similar_object, 0, ' And we emptied out the similar object checking the first');
}

is($at->flush($fake_symbol),     2, 'We just flushed our fake key by symbol for both backing stores');
is($at->flush($fake_underlying), 0, '... using the underlying does not remove anything');
ok($at->flush, '... removing all of the keys finds the stores for the ersatz underlying.');

my $old_epoch = Date::Utility->new('15-Mar-12')->epoch - 1;                  # End of the 14th, which is in our sandbox data
my $whole_day = Time::Duration::Concise::Localize->new(interval => '24h');

my ($fill_count, $first_fill, $last_fill) = $big_at->fill_from_historical_feed({
    underlying   => $real_underlying,
    ending_epoch => $old_epoch,
    interval     => $whole_day,
});

is($fill_count, 143, 'Able to load in ticks from the past');
my @old_ticks = @{
    $big_at->retrieve({
            underlying   => $real_underlying,
            interval     => $whole_day,
            ending_epoch => $old_epoch,
            fill_cache   => 0,
        })};
is(scalar @old_ticks, 144, 'Got the 144 expected aggregations for our symbol');
is(
    scalar @{
        $at->retrieve({
                underlying   => $fake_underlying,
                interval     => $whole_day,
                ending_epoch => $now,
                fill_cache   => 0,
            })
    },
    0,
    'Differently configured object is still empty'
);
is(
    $big_at->add({
            symbol => $real_symbol,
            epoch  => $old_epoch - 1,
            quote  => 100,
        }
    ),
    1,
    'Able to add a tick at the end of day'
);

ok $big_at->flush, "Flushing all 600s entries";

done_testing;
