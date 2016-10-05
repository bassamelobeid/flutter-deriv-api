#!/etc/rmg/bin/perl

use strict;
use warnings;
use utf8;
use Test::More 0.22 tests => 4;
use Test::Exception;
use Test::Warn;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

use Postgres::FeedDB::Spot::DatabaseAPI;
use Postgres::FeedDB::Spot::OHLC;
use DateTime;
use Date::Utility;

my $dbh = Postgres::FeedDB::read_dbh;
$dbh->{RaiseError} = 1;

subtest 'prepare ohlc' => sub {
    subtest 'Daily Official' => sub {
        my @daily = (
            [78.5529, 78.7057, 77.6673, 78.0138],
            [78.074,  78.4173, 77.9802, 78.3566],
            [78.3573, 78.9647, 78.1122, 78.7438],
            [78.7439, 79.3997, 78.6141, 79.3082],
            [79.2964, 79.792,  79.2088, 79.7045],
            [79.7091, 79.7315, 79.1173, 79.4677],
            [79.5622, 79.7253, 79.2328, 79.3149],
            [79.3159, 79.6967, 79.1693, 79.5313],
            [79.5246, 79.7525, 79.2983, 79.3833],
            [79.3826, 79.4787, 79.1637, 79.4294],
            [79.4281, 79.5145, 78.6135, 78.7104],
            [79.0778, 79.3046, 78.8644, 79.0258],
            [79.0318, 79.1252, 78.8493, 79.0611],
            [79.0642, 79.7028, 78.7929, 79.4379],
            [79.4374, 80.3417, 79.3906, 80.0522],
            [80.0527, 80.5707, 80.0523, 80.4291],
            [80.5754, 80.5827, 79.4401, 79.6575],
            [79.6696, 79.7927, 79.2364, 79.4684],
            [79.4671, 79.8709, 79.3542, 79.6773],
            [79.6797, 79.6976, 79.2243, 79.3026],
            [79.3076, 79.9973, 79.1377, 79.7984],
        );
        my $day = 1;
        for my $ohlc (@daily) {
            my ($open, $high, $low, $close) = @$ohlc;
            my $date = DateTime->new(
                year  => 2012,
                month => 6,
                day   => $day++
            );
            lives_ok {
                BOM::Test::Data::Utility::FeedTestDatabase::create_ohlc_daily({
                    epoch    => $date->epoch,
                    open     => $open,
                    high     => $high,
                    low      => $low,
                    close    => $close,
                    official => 1
                });
            }
            'Daily Official ' . $date->dmy . ' ' . $date->hms;
        }
    };
};

subtest 'Daily - Start-End - Official' => sub {
    my $api = Postgres::FeedDB::Spot::DatabaseAPI->new(
        underlying        => 'frxUSDJPY',
        use_official_ohlc => 1,
        db_handle         => $dbh,
    );

    my $ticks = $api->ohlc_start_end({
        start_time         => '2012-06-01 00:00:00',
        end_time           => '2012-06-21 23:59:59',
        aggregation_period => 24 * 60 * 60
    });
    isa_ok $ticks, 'ARRAY', 'Got ticks for 2012-06-01 00:00:00 to 2012-06-21 23:59:8 and';
    is scalar @$ticks, 21, 'All in all 21 ticks found';

    subtest 'OHLC datatype' => sub {
        foreach my $tick (@$ticks) {
            my $date = Date::Utility->new({epoch => $tick->epoch});
            isa_ok $tick, 'Postgres::FeedDB::Spot::OHLC', $date->datetime_yyyymmdd_hhmmss;
        }
    };

    subtest 'Order Check - Descending' => sub {
        my $previous_tick = 99999999999;
        foreach my $tick (@$ticks) {
            my $date = Date::Utility->new({epoch => $tick->epoch});
            ok $tick->epoch < $previous_tick, 'Checking ' . $date->datetime_yyyymmdd_hhmmss;
            $previous_tick = $tick->epoch;
        }
    };

    subtest 'No frxAUDCAD' => sub {
        foreach my $tick (@$ticks) {
            my $date = Date::Utility->new({epoch => $tick->epoch});
            ok $tick->open > 2, 'Tick at ' . $date->datetime_yyyymmdd_hhmmss . ' is frxUSDJPY';
        }
    };
};

subtest 'Daily - Start-End - Simple' => sub {
    my $api = Postgres::FeedDB::Spot::DatabaseAPI->new(
        underlying        => 'frxUSDJPY',
        use_official_ohlc => 1,
        db_handle         => $dbh,
    );

    my $ticks = $api->ohlc_start_end({
        start_time         => '2012-06-01 00:00:00',
        end_time           => '2012-07-01 00:00:00',
        aggregation_period => 86400
    });
    isa_ok $ticks, 'ARRAY', 'Got ticks for 2012-06-01 00:00:00 to 2012-07-01 00:00:00 and';
    is scalar @$ticks, 21, 'All in all 21 ticks found';

    subtest 'OHLC datatype' => sub {
        foreach my $tick (@$ticks) {
            my $date = Date::Utility->new({epoch => $tick->epoch});
            isa_ok $tick, 'Postgres::FeedDB::Spot::OHLC', $date->datetime_yyyymmdd_hhmmss;
        }
    };

    subtest 'Order Check - Descending' => sub {
        my $previous_tick = 99999999999;
        foreach my $tick (@$ticks) {
            my $date = Date::Utility->new({epoch => $tick->epoch});
            ok $tick->epoch < $previous_tick, 'Checking ' . $date->datetime_yyyymmdd_hhmmss;
            $previous_tick = $tick->epoch;
        }
    };

    subtest 'No frxAUDCAD' => sub {
        foreach my $tick (@$ticks) {
            my $date = Date::Utility->new({epoch => $tick->epoch});
            ok $tick->open > 2, 'Tick at ' . $date->datetime_yyyymmdd_hhmmss . ' is frxUSDJPY';
        }
    };
};

subtest 'Daily - Start-End - Beserk User' => sub {
    my $api = Postgres::FeedDB::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);

    throws_ok {
        warnings_like {
            my $ticks = $api->ohlc_start_end({
                start_time => '2012-07-09 00:00:00',
                end_time   => '2012-07-09 00:30:00'
            });
        }
        qr/Error/;
    }
    qr/Error ohlc_aggregation_function: aggregation_period\(<NULL>\) should be provided/,
        'No Aggregation Period - We don\'t entertain such queries 1';

    throws_ok {
        warnings_like {
            my $ticks = $api->ohlc_start_end({
                end_time           => '2012-07-09 00:30:00',
                aggregation_period => 24 * 60 * 60
            });
        }
        qr/Error/;
    }
    qr/Error sanity_checks_start_end: start time\(<NULL>\) and end time\(2012-07-09 00:30:00\) should be provided/,
        'No Start Time -  We don\'t entertain such queries 2';

    throws_ok {
        warnings_like {
            my $ticks = $api->ohlc_start_end({
                start_time         => '2012-07-09 00:00:00',
                aggregation_period => 24 * 60 * 60
            });
        }
        qr/Error/;
    }
    qr/Error sanity_checks_start_end: start time\(2012-07-09 00:00:00\) and end time\(<NULL>\) should be provided/,
        'No Start Time -  We don\'t entertain such queries 3';
};

