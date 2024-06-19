use strict;
use warnings;

use Test::Most;
use Test::FailWarnings;
use Test::MockModule;
use File::Spec;

use BOM::Test::Data::Utility::UnitTestRedis;

use BOM::MarketData qw(create_underlying);
#use BOM::Test::Data::Utility::FeedTestDatabase qw( :init );

use BOM::Market::DataDecimate;
use Text::CSV;
use BOM::Config::Chronicle;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Config::Redis;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use Volatility::EconomicEvents;

my $now = Date::Utility->new->epoch;
$now = $now - $now % 60;

BOM::Config::Redis::redis_replicated_write()->set('economic_events_cache_snapshot', time);

my $data = generate_data();

foreach my $tick (@$data) {
    # Populate data into database for backpricing purpose
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => $tick->{epoch},
        quote      => $tick->{quote},
    });
}

# Events for checking the filtering logic
my $events = [{
        release_date => $now,
        symbol       => 'USD',
        event_name   => "Non-Farm Employment Change",
        custom       => {
            frxUSDJPY => {
                vol_change   => 0.3,
                decay_factor => 4,
                duration     => 300
            },
        },
    },
    {
        release_date => $now + 60 * 60,
        symbol       => 'USD',
        event_name   => "Crude Oil Inventories",
        custom       => {
            frxUSDJPY => {
                vol_change   => 0.3,
                decay_factor => 4,
                duration     => 300
            },
        },
    },
    {
        release_date => $now + 60 * 90,
        symbol       => 'USD',
        event_name   => "Federal Funds Rate",
        custom       => {
            frxUSDJPY => {
                vol_change   => 0.3,
                decay_factor => 4,
                duration     => 300
            },
        },
    }];
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'economic_events',
    {
        events        => $events,
        recorded_date => $now
    });

my $cw = BOM::Config::Chronicle::get_chronicle_writer();
Volatility::EconomicEvents::generate_variance({
    underlying_symbols => ['frxUSDJPY'],
    economic_events    => $events,
    chronicle_writer   => $cw,
    date               => $now
});

subtest "filter ticks within economic events interval" => sub {

    my $decimate_data;     # Streaming data for pricing
    my $backprice_data;    # Historical data for backpricing
    my $minmax_data;       # Historical data for min max (not affected by filtering)

    my $decimate_cache = BOM::Market::DataDecimate->new({market => 'forex'});

    ok $decimate_cache, "Instance has been created";

    my $time = $now - 1;

    my $i = 1;

    # Populate first 5 minutes ticks
    while ($i <= 5 * 60 / 5) {
        $decimate_cache->data_cache_insert_raw($data->[$i - 1]);
        if (($i - 1) % 3 == 0) {
            $decimate_cache->data_cache_insert_decimate('frxUSDJPY', $data->[$i - 1]->{epoch});
        }
        $time += 5;
        $i    += 1;
    }

    $decimate_data = $decimate_cache->_get_decimate_from_cache({
        symbol      => 'frxUSDJPY',
        start_epoch => $time - 30 * 60,
        end_epoch   => $time,
    });

    is scalar(@$decimate_data), '0', "Streaming data for the first 5 minutes are filtered due to economic event";

    $backprice_data = $decimate_cache->decimate_cache_get({
        underlying  => create_underlying('frxUSDJPY', Date::Utility->new($time)),
        start_epoch => $time - 30 * 60,
        end_epoch   => $time,
        backprice   => 1
    });

    is scalar(@$backprice_data), scalar(@$decimate_data), "Consistent with streaming data";

    $minmax_data = $decimate_cache->decimate_cache_get({
        underlying  => create_underlying('frxUSDJPY', Date::Utility->new($time)),
        start_epoch => $time - 30 * 60,
        end_epoch   => $time,
        backprice   => 1,
        min_max     => 1
    });

    is scalar(@$minmax_data), 5 * 60 / 15, "Min max data is not affected";

    # Populate first 6 minutes ticks
    while ($i <= 6 * 60 / 5) {
        $decimate_cache->data_cache_insert_raw($data->[$i - 1]);
        if (($i - 1) % 3 == 0) {
            $decimate_cache->data_cache_insert_decimate('frxUSDJPY', $data->[$i - 1]->{epoch});
        }
        $time += 5;
        $i    += 1;
    }

    $decimate_data = $decimate_cache->_get_decimate_from_cache({
        symbol      => 'frxUSDJPY',
        start_epoch => $time - 30 * 60,
        end_epoch   => $time,
    });

    # Decimate data starts populating at minute 6
    is scalar(@$decimate_data), 4 * 1, "Streaming data after the end of economic event";

    is $decimate_data->[-1]->{decimate_epoch} + 15 - $decimate_data->[0]->{decimate_epoch}, 1 * 60, "Total 1 minute of streaming data";

    $backprice_data = $decimate_cache->decimate_cache_get({
        underlying  => create_underlying('frxUSDJPY', Date::Utility->new($time)),
        start_epoch => $time - 30 * 60,
        end_epoch   => $time,
        backprice   => 1
    });

    is scalar(@$backprice_data), scalar(@$decimate_data), "Consistent with streaming data";

    is $backprice_data->[-1]->{decimate_epoch}, $decimate_data->[-1]->{decimate_epoch}, "Consistent with streaming data";
    is $backprice_data->[0]->{decimate_epoch},  $decimate_data->[0]->{decimate_epoch},  "Consistent with streaming data";

    $minmax_data = $decimate_cache->decimate_cache_get({
        underlying  => create_underlying('frxUSDJPY', Date::Utility->new($time)),
        start_epoch => $time - 30 * 60,
        end_epoch   => $time,
        backprice   => 1,
        min_max     => 1
    });

    is scalar(@$minmax_data), 6 * 60 / 15, "Min max data is not affected";

    # Populate first 20 minutes ticks
    while ($i <= 20 * 60 / 5) {
        $decimate_cache->data_cache_insert_raw($data->[$i - 1]);
        if (($i - 1) % 3 == 0) {
            $decimate_cache->data_cache_insert_decimate('frxUSDJPY', $data->[$i - 1]->{epoch});
        }
        $time += 5;
        $i    += 1;
    }

    $decimate_data = $decimate_cache->_get_decimate_from_cache({
        symbol      => 'frxUSDJPY',
        start_epoch => $time - 30 * 60,
        end_epoch   => $time,
    });

    is scalar(@$decimate_data), 4 * 15, "Streaming data at minute 20";

    is $decimate_data->[-1]->{decimate_epoch} + 15 - $decimate_data->[0]->{decimate_epoch}, 15 * 60, "Total 15 minutes of streaming data";

    $backprice_data = $decimate_cache->decimate_cache_get({
        underlying  => create_underlying('frxUSDJPY', Date::Utility->new($time)),
        start_epoch => $time - 30 * 60,
        end_epoch   => $time,
        backprice   => 1
    });

    is scalar(@$backprice_data), scalar(@$decimate_data), "Consistent with streaming data";

    is $backprice_data->[-1]->{decimate_epoch}, $decimate_data->[-1]->{decimate_epoch}, "Consistent with streaming data";
    is $backprice_data->[0]->{decimate_epoch},  $decimate_data->[0]->{decimate_epoch},  "Consistent with streaming data";

    $minmax_data = $decimate_cache->decimate_cache_get({
        underlying  => create_underlying('frxUSDJPY', Date::Utility->new($time)),
        start_epoch => $time - 30 * 60,
        end_epoch   => $time,
        backprice   => 1,
        min_max     => 1
    });

    is scalar(@$minmax_data), 20 * 60 / 15, "Min max data is not affected";

    # Populate first 70 minutes ticks
    while ($i <= 70 * 60 / 5) {
        $decimate_cache->data_cache_insert_raw($data->[$i - 1]);
        if (($i - 1) % 3 == 0) {
            $decimate_cache->data_cache_insert_decimate('frxUSDJPY', $data->[$i - 1]->{epoch});
        }
        $time += 5;
        $i    += 1;
    }

    $decimate_data = $decimate_cache->_get_decimate_from_cache({
        symbol      => 'frxUSDJPY',
        start_epoch => $time - 30 * 60,
        end_epoch   => $time,
    });

    is scalar(@$decimate_data), 4 * 30, "Full 30 minutes of decimate data";

    # News event occured at 60th minute, the data from the intervals from [60, 65) are filtered.

    is $decimate_data->[-1]->{decimate_epoch} + 15 - $decimate_data->[0]->{decimate_epoch}, 30 * 60 + 5 * 60,
        "Extra 5 minutes to get top 120 decimate data";

    $backprice_data = $decimate_cache->decimate_cache_get({
        underlying  => create_underlying('frxUSDJPY', Date::Utility->new($time)),
        start_epoch => $time - 30 * 60,
        end_epoch   => $time,
        backprice   => 1
    });

    is scalar(@$backprice_data), scalar(@$decimate_data), "Consistent with streaming data";

    is $backprice_data->[-1]->{decimate_epoch}, $decimate_data->[-1]->{decimate_epoch}, "Consistent with streaming data";
    is $backprice_data->[0]->{decimate_epoch},  $decimate_data->[0]->{decimate_epoch},  "Consistent with streaming data";

    $minmax_data = $decimate_cache->decimate_cache_get({
        underlying  => create_underlying('frxUSDJPY', Date::Utility->new($time)),
        start_epoch => $time - 30 * 60,
        end_epoch   => $time,
        back_price  => 1,
        min_max     => 1
    });

    is scalar(@$minmax_data), 30 * 60 / 15, "Min max data is not affected";

    # Test the filtering when there is no raw tick for streaming data

    while ($i <= 100 * 60 / 5) {

        if (($i - 1) % 3 == 0) {
            $decimate_cache->data_cache_insert_decimate('frxUSDJPY', $data->[$i - 1]->{epoch});
        }
        $time += 5;
        $i    += 1;
    }

    $decimate_data = $decimate_cache->_get_decimate_from_cache({
        symbol      => 'frxUSDJPY',
        start_epoch => $time - 30 * 60,
        end_epoch   => $time,
    });

    is scalar(@$decimate_data), 4 * 30, "Full 30 minutes of decimate data";

    # News event occured at 90th minute, it should be filtered.

    is $decimate_data->[-1]->{decimate_epoch} + 15 - $decimate_data->[0]->{decimate_epoch}, 30 * 60 + 5 * 60,
        "Extra 5 minutes to get top 120 decimate data";
};

sub generate_data {

    my $data = [];

    my $price = 100;

    for (my $i = $now; $i <= $now + 60 * 60 * 3; $i = $i + 5) {
        my $info = {
            'symbol' => 'frxUSDJPY',
            'epoch'  => $i,
            'bid'    => $price,
            'ask'    => $price,
            'quote'  => $price
        };
        push @$data, $info;
    }
    return $data;
}

done_testing;
