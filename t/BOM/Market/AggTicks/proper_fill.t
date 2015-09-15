use strict;
use warnings;

use Test::Most;
use Test::FailWarnings;

use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Market::AggTicks;

new_ok('BOM::Market::AggTicks');

my $test_symbol = 'XYZ';
my $through     = 900;

my $dense_ticks = [map { +{epoch => $_, quote => $_, symbol => $test_symbol} } (0 .. $through)];

my $at = BOM::Market::AggTicks->new;
$at->flush;

subtest 'Dense ticks' => sub {
    foreach my $run (0 .. 1) {
        my $test_name = ($run) ? 'Dense reload' : 'Dense load';
        subtest $test_name => sub {
            my ($count, $first, $last) = $at->fill_from_historical_feed({
                underlying   => $test_symbol,
                ticks        => $dense_ticks,
                ending_epoch => $through,
                fast_insert  => $run,
            });

            is $count, $through / $at->agg_interval->seconds, 'Filled proper aggregation count';
            is $first->epoch, 15, 'Starting at the 15 epoch';
            is $last->epoch, $through, 'Ending at our final epoch';
            my $back_aways = $through - 15;
            eq_or_diff(
                $at->retrieve({
                        underlying   => $test_symbol,
                        ending_epoch => $back_aways,
                        tick_count   => 2,
                        fill_cache   => 0,
                    }
                ),
                [{
                        count  => 1,
                        symbol => 'XYZ',
                        epoch  => $back_aways - 1,
                        quote  => $back_aways - 1,
                    },
                    {
                        count  => 1,
                        symbol => 'XYZ',
                        epoch  => $back_aways,
                        quote  => $back_aways,
                    },
                ],
                'Got proper latest ticks'
            );
            my $stuff = $at->retrieve({
                underlying   => $test_symbol,
                ending_epoch => $through,
                fill_cache   => 0
            });
            is(
                scalar @{
                    $at->retrieve({
                            underlying   => $test_symbol,
                            ending_epoch => $through,
                            fill_cache   => 0
                        })
                },
                60,
                'Got back our 60 aggregations'
            );
        };
    }
};

$at->flush;
$through = 180;
my $sparse_ticks = [map { +{epoch => $_, quote => $_, symbol => $test_symbol} } (1, 31, 61, 74, 91, $through, $through + 1)];

subtest 'Sparse ticks' => sub {
    foreach my $run (0 .. 1) {
        my $test_name = ($run) ? 'Sparse reload' : 'Sparse load';
        subtest $test_name => sub {
            my ($count, $first, $last) = $at->fill_from_historical_feed({
                underlying   => $test_symbol,
                ticks        => $sparse_ticks,
                ending_epoch => $through,
                fast_insert  => $run,
            });

            is $count, $through / $at->agg_interval->seconds, 'Filled proper aggregation count';
            is $first->epoch, 15, 'Starting at the 15 epoch';
            is $last->epoch, $through, 'Ending at our final epoch';
            eq_or_diff(
                $at->retrieve({
                        underlying   => $test_symbol,
                        ending_epoch => $through,
                        tick_count   => 2,
                        fill_cache   => 0,
                    }
                ),
                [{
                        count  => 1,
                        symbol => 'XYZ',
                        epoch  => 91,
                        quote  => 91,
                    },
                    {
                        count  => 1,
                        symbol => 'XYZ',
                        epoch  => $through,
                        quote  => $through,
                    },
                ],
                'Got proper latest ticks'
            );
            my $stuff = $at->retrieve({
                underlying   => $test_symbol,
                ending_epoch => $through,
                fill_cache   => 0
            });
            eq_or_diff(
                $stuff->[2],
                {
                    agg_epoch => 45,
                    count     => 1,
                    epoch     => 31,
                    quote     => 31,
                    symbol    => 'XYZ',
                },
                'The first sparse but newly filled tick has the proper count data, especially count'
            );
            eq_or_diff(
                $stuff->[3],
                {
                    agg_epoch => 60,
                    count     => 0,
                    epoch     => 31,
                    quote     => 31,
                    symbol    => 'XYZ',
                },
                '.. and the following tick is also correct'
            );
            is(scalar @$stuff, 12, 'Got our 12 aggregations...');
            $stuff = $at->retrieve({
                underlying   => $test_symbol,
                ending_epoch => $through + 2,
                fill_cache   => 0
            });
            is(scalar @$stuff, 13, 'Then plus another one..');
            eq_or_diff(
                $stuff->[-1],
                {
                    count  => 1,
                    epoch  => $through + 1,
                    quote  => $through + 1,
                    symbol => $test_symbol,
                },
                ' which is the latest tick '
            );
        };
    }
};

done_testing;
