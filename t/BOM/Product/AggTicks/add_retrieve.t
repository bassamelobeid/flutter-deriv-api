use Test::Most;
use Test::FailWarnings;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Data::Utility::UnitTestCouchDB qw( :init );

use BOM::Market::Underlying;
use BOM::Test::Data::Utility::FeedTestDatabase qw( :init );
use BOM::Platform::Runtime;

use BOM::Market::AggTicks;

BOM::Platform::Runtime->instance->app_config->system->directory->feed('/home/git/bom/t/data/feed/');

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol => 'FOREX',
        date   => Date::Utility->new,
    });
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
    namespace          => $namespace,
    agg_interval       => $agg,
    returns_interval   => $agg,
    retention_interval => $retention
});
my $big_at = BOM::Market::AggTicks->new({
    namespace          => $namespace,
    agg_interval       => 600,
    returns_interval   => 600,
    retention_interval => 86399,
});

my $now = time;
$now = $now - ($now % $at->agg_interval->seconds);
my $count = 10 + rand(5);    # Randomized but constant for reasonable testing.

foreach my $i (1 .. 6) {
    $at->add({
        underlying => $fake_underlying,
        epoch      => $now - $i * $agg,
        value      => $i,
        full_count => $count,
        high       => $i + 0.5,
        low        => $i - 0.5,
    });
    $at->add({
        underlying => $ersatz_underlying,
        epoch      => $now - $i * $agg,
        value      => $i,
        full_count => $count,
        high       => $i + 0.5,
        low        => $i - 0.5,
    });
}

throws_ok { $at->add({underlying => $fake_underlying, epoch => $now - 1}) }
qr/Unrecoverable error: supplied epoch .* does not fall on .* boundary, off by \d seconds/,
    'Cannot add ticks which do not fall on aggregation boundaries';

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

foreach my $interval (keys %intervals) {
    my $ti = Time::Duration::Concise::Localize->new(interval => $interval);
    my @same_object = @{
        $at->retrieve({
                underlying   => $fake_underlying,
                interval     => $ti,
                ending_epoch => $now,
            })};
    my @similar_object = @{
        $similar_at->retrieve({
                underlying   => $fake_underlying,
                interval     => $ti,
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
subtest 'chunked access' => sub {
    plan tests => 2;
    my @chunks = @{
        $at->retrieve({
                underlying   => $fake_underlying,
                interval     => Time::Duration::Concise::Localize->new(interval => '1d'),
                ending_epoch => $now,
                fill_cache   => 0,
                chunks       => 24,
            })};
    is(scalar @chunks, 24, 'Got the 24 requested chunks for the period.');
    my @empties = grep { !@$_ } @chunks;
    is(scalar @empties, 19, '...even though 19 of them are empty.');

};

is($at->flush($fake_symbol),     1, 'We just flushed our fake key by symbol');
is($at->flush($fake_underlying), 0, '... using the underlying does not remove anything');
is($at->flush,                   1, '... removing all of the keys finds the ersatz underlying.');

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
is(scalar @old_ticks, 143, 'Got the 143 expected aggregations for our symbol');
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
is($at->flush, 0, 'Flushing an empty db gives 0 removed');
my @unflushed_ticks = @{
    $big_at->retrieve({
            underlying   => $real_underlying,
            interval     => $whole_day,
            ending_epoch => $old_epoch,
            fill_cache   => 0,
        })};
is_deeply(\@unflushed_ticks, \@old_ticks, 'Flushing the other one did not break this one');
is(
    $big_at->add({
            underlying => $real_underlying,
            epoch      => $old_epoch - 1,
            value      => 100,
            aggregated => 0
        }
    ),
    1,
    'Able to add a tick at the end of day'
);
my @plus_ua = @{
    $big_at->retrieve({
            underlying   => $real_underlying,
            interval     => $whole_day,
            ending_epoch => $old_epoch,
            fill_cache   => 0,
        })};
my $last_tick = pop @plus_ua;
is($last_tick->{value}, 100, 'The latest tick seems to have our value');
is_deeply(\@plus_ua, \@old_ticks, 'Minus the final tick, the rest is the same');

is(
    $big_at->add({
            underlying => $real_underlying,
            epoch      => $old_epoch + $big_at->agg_interval->seconds + 1,
            value      => 200,
            aggregated => 0
        }
    ),
    1,
    'Able to add a tick past the end of day and next period'
);
cmp_ok($big_at->unaggregated_periods($real_underlying), '>', 1, 'More than 1 unaggregated period in our data now.');
@plus_ua = @{
    $big_at->retrieve({
            underlying   => $real_underlying,
            interval     => $whole_day,
            ending_epoch => $old_epoch,
            fill_cache   => 0,
        })};

$last_tick = pop @plus_ua;
is($last_tick->{value}, 100, 'The latest tick is not the one added past the end of our period');

is(
    $big_at->aggregate_to_epoch({
            underlying => $real_underlying,
            epoch      => $old_epoch + 1
        }
    ),
    1,
    'Can aggregate to the start of the next day'
);
is($big_at->unaggregated_periods($real_underlying), 0, 'No unaggregated data.');

my @after_agg = @{
    $big_at->retrieve({
            underlying   => $real_underlying,
            interval     => $whole_day,
            ending_epoch => $old_epoch,
            fill_cache   => 0,
        })};

is_deeply(\@after_agg, \@old_ticks, 'After aggregation, those ticks belong to the next day');

ok $big_at->flush, "Flushing all 600s entries";

my $test_db = BOM::Test::Data::Utility::FeedTestDatabase->new();

done_testing;
