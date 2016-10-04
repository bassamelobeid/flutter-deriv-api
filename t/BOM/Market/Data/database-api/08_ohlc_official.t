use Test::Most;
use utf8;
use Test::FailWarnings;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

use Postgres::FeedDB::Spot::DatabaseAPI;
use Postgres::FeedDB::Spot::OHLC;
use DateTime;
use Date::Utility;
use BOM::Market::Underlying;
use Date::Parse;

my $dbh = BOM::Database::FeedDB::read_dbh;
$dbh->{RaiseError} = 1;

subtest 'prepare ohlc - DJI' => sub {
    subtest 'Daily Non-Official' => sub {
        my @daily = (

            {
                date  => '2012-06-01 00:00:00',
                quote => 12388.56,
                bid   => 12388.56,
                ask   => 12388.56
            },
            {
                date  => '2012-06-01 04:10:10',
                quote => 12391.63,
                bid   => 12391.63,
                ask   => 12391.63
            },
            {
                date  => '2012-06-01 09:20:20',
                quote => 12117.48,
                bid   => 12117.48,
                ask   => 12117.48
            },
            {
                date  => '2012-06-01 13:40:40',
                quote => 12114.57,
                bid   => 12114.57,
                ask   => 12114.57
            },

            {
                date  => '2012-06-04 00:00:00',
                quote => 12119.85,
                bid   => 12119.85,
                ask   => 12119.85
            },
            {
                date  => '2012-06-04 04:10:10',
                quote => 12143.69,
                bid   => 12143.69,
                ask   => 12143.69
            },
            {
                date  => '2012-06-04 09:20:20',
                quote => 12035.09,
                bid   => 12035.09,
                ask   => 12035.09
            },
            {
                date  => '2012-06-04 13:40:40',
                quote => 12101.46,
                bid   => 12101.46,
                ask   => 12101.46
            },

            {
                date  => '2012-06-05 00:00:00',
                quote => 12103.08,
                bid   => 12103.08,
                ask   => 12103.08
            },
            {
                date  => '2012-06-05 04:10:10',
                quote => 12145.55,
                bid   => 12145.55,
                ask   => 12145.55
            },
            {
                date  => '2012-06-05 09:20:20',
                quote => 12071.17,
                bid   => 12071.17,
                ask   => 12071.17
            },
            {
                date  => '2012-06-05 13:40:40',
                quote => 12127.35,
                bid   => 12127.35,
                ask   => 12127.35
            },

            {
                date  => '2012-06-06 00:00:00',
                quote => 12125,
                bid   => 12125,
                ask   => 12125
            },
            {
                date  => '2012-06-06 04:10:10',
                quote => 12414.79,
                bid   => 12414.79,
                ask   => 12414.79
            },
            {
                date  => '2012-06-06 09:20:20',
                quote => 12125,
                bid   => 12125,
                ask   => 12125
            },
            {
                date  => '2012-06-06 13:40:40',
                quote => 12414.79,
                bid   => 12414.79,
                ask   => 12414.79
            },

            {
                date  => '2012-06-07 00:00:00',
                quote => 12416.53,
                bid   => 12416.53,
                ask   => 12416.53
            },
            {
                date  => '2012-06-07 04:10:10',
                quote => 12555.26,
                bid   => 12555.26,
                ask   => 12555.26
            },
            {
                date  => '2012-06-07 09:20:20',
                quote => 12416.53,
                bid   => 12416.53,
                ask   => 12416.53
            },
            {
                date  => '2012-06-07 13:40:40',
                quote => 12460.96,
                bid   => 12460.96,
                ask   => 12460.96
            },

            {
                date  => '2012-06-08 00:00:00',
                quote => 12460.81,
                bid   => 12460.81,
                ask   => 12460.81
            },
            {
                date  => '2012-06-08 04:10:10',
                quote => 12554.2,
                bid   => 12554.2,
                ask   => 12554.2
            },
            {
                date  => '2012-06-08 09:20:20',
                quote => 12398.44,
                bid   => 12398.44,
                ask   => 12398.44
            },
            {
                date  => '2012-06-08 13:40:40',
                quote => 12554.2,
                bid   => 12554.2,
                ask   => 12554.2
            },

            {
                date  => '2012-06-11 00:00:00',
                quote => 12553.81,
                bid   => 12553.81,
                ask   => 12553.81
            },
            {
                date  => '2012-06-11 04:10:10',
                quote => 12650.47,
                bid   => 12650.47,
                ask   => 12650.47
            },
            {
                date  => '2012-06-11 09:20:20',
                quote => 12398.48,
                bid   => 12398.48,
                ask   => 12398.48
            },
            {
                date  => '2012-06-11 13:40:40',
                quote => 12411.23,
                bid   => 12411.23,
                ask   => 12411.23
            },

            {
                date  => '2012-06-12 00:00:00',
                quote => 12412.07,
                bid   => 12412.07,
                ask   => 12412.07
            },
            {
                date  => '2012-06-12 04:10:10',
                quote => 12577.02,
                bid   => 12577.02,
                ask   => 12577.02
            },
            {
                date  => '2012-06-12 09:20:20',
                quote => 12411.91,
                bid   => 12411.91,
                ask   => 12411.91
            },
            {
                date  => '2012-06-12 13:40:40',
                quote => 12573.8,
                bid   => 12573.8,
                ask   => 12573.8
            },

            {
                date  => '2012-06-13 00:00:00',
                quote => 12533.38,
                bid   => 12533.38,
                ask   => 12533.38
            },
            {
                date  => '2012-06-13 04:10:10',
                quote => 12578.25,
                bid   => 12578.25,
                ask   => 12578.25
            },
            {
                date  => '2012-06-13 09:20:20',
                quote => 12493.69,
                bid   => 12493.69,
                ask   => 12493.69
            },
            {
                date  => '2012-06-13 13:40:40',
                quote => 12477.38,
                bid   => 12477.38,
                ask   => 12477.38
            },

            {
                date  => '2012-06-14 13:40:40',
                quote => 12477.38,
                bid   => 12477.38,
                ask   => 12477.38
            },

        );

        foreach my $ohlc (@daily) {
            lives_ok {
                BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
                    epoch      => Date::Parse::str2time($ohlc->{date}),
                    quote      => $ohlc->{quote},
                    bid        => $ohlc->{bid},
                    ask        => $ohlc->{ask},
                    underlying => 'DJI'
                });
            }
            'for ohlc daily - ' . $ohlc->{date};
        }

    };

    subtest 'Daily Official' => sub {
        my @daily = (
            ['2012-06-01', 12_391.56, 12_391.63, 12_107.48, 12_118.57],
            ['2012-06-04', 12_119.85, 12_143.69, 12_035.09, 12_101.46],
            ['2012-06-05', 12_101.08, 12_147.55, 12_072.17, 12_127.95],
            ['2012-06-06', 12_125.00, 12_414.79, 12_125.00, 12_414.79],
            ['2012-06-07', 12_416.53, 12_555.26, 12_416.53, 12_460.96],
            ['2012-06-08', 12_460.81, 12_554.20, 12_398.44, 12_554.20],
            ['2012-06-11', 12_553.81, 12_650.47, 12_398.48, 12_411.23],
            ['2012-06-12', 12_412.07, 12_577.02, 12_411.91, 12_573.80],
            ['2012-06-13', 12_566.38, 12_598.25, 12_453.69, 12_496.38],
        );
        for my $ohlc (@daily) {
            my ($date, $open, $high, $low, $close) = @$ohlc;
            $date = Date::Utility->new($date);

            lives_ok {
                BOM::Test::Data::Utility::FeedTestDatabase::create_ohlc_daily({
                    epoch      => $date->epoch,
                    open       => $open,
                    high       => $high,
                    low        => $low,
                    close      => $close,
                    official   => 1,
                    underlying => 'DJI'
                });
            }
            'Daily Official ' . $date->date_yyyymmdd;
        }
    };
};

subtest 'Daily - Start-End - Simple' => sub {
    my $api = Postgres::FeedDB::Spot::DatabaseAPI->new(
        underlying        => 'DJI',
        use_official_ohlc => 1,
        db_handle         => $dbh,
    );
    my $unofficial_api = Postgres::FeedDB::Spot::DatabaseAPI->new(underlying => 'DJI', db_handle => $dbh);
    my ($ohlcs, $unofficial, $official);
    my $start_time = '2012-06-01';
    my $end_time   = '2012-07-01';

    subtest 'By default is unofficial' => sub {
        $ohlcs = $unofficial_api->ohlc_start_end({
            start_time         => $start_time,
            end_time           => $end_time,
            aggregation_period => 86400
        });
        is scalar @$ohlcs, 9, 'All in all 9 ticks found';

        subtest 'unofficial OHLC Data Check' => sub {
            my $ohlc = $ohlcs->[0];
            is $ohlc->epoch, Date::Utility->new('2012-06-13')->epoch, 'epoch ok';
            is $ohlc->open,  12_533.38, 'open ok';
            is $ohlc->high,  12_578.25, 'high ok';
            is $ohlc->low,   12_477.38, 'low ok';
            is $ohlc->close, 12_477.38, 'close ok';

            $ohlc = $ohlcs->[8];
            is $ohlc->epoch, Date::Utility->new('2012-06-01')->epoch, 'epoch ok';
            is $ohlc->open,  12_388.56, 'open ok';
            is $ohlc->high,  12_391.63, 'high ok';
            is $ohlc->low,   12_114.57, 'low ok';
            is $ohlc->close, 12_114.57, 'close ok';
        };
    };

    subtest 'Ask for official explicitly' => sub {
        $official = $api->ohlc_start_end({
            start_time         => $start_time,
            end_time           => $end_time,
            aggregation_period => 86400,
        });

        is scalar @$official, 9, 'All in all 9 ticks found';

        subtest 'Official OHLC Data Check' => sub {
            my $ohlc = $official->[0];
            is $ohlc->epoch, Date::Utility->new('2012-06-13')->epoch, 'epoch ok';
            is $ohlc->open,  12_566.38, 'open ok';
            is $ohlc->high,  12_598.25, 'high ok';
            is $ohlc->low,   12_453.69, 'low ok';
            is $ohlc->close, 12_496.38, 'close ok';

            $ohlc = $official->[8];
            is $ohlc->epoch, Date::Utility->new('2012-06-01')->epoch, 'epoch ok';
            is $ohlc->open,  12_391.56, 'open ok';
            is $ohlc->high,  12_391.63, 'high ok';
            is $ohlc->low,   12_107.48, 'low ok';
            is $ohlc->close, 12_118.57, 'close ok';
        };
    };

    subtest 'Access through Underlying' => sub {
        my $underlying       = BOM::Market::Underlying->new('DJI');
        my $ohlcs_underlying = $underlying->ohlc_between_start_end({
            start_time         => $start_time,
            end_time           => $end_time,
            aggregation_period => 86400,
        });
        is_deeply($ohlcs_underlying, $official, 'check official OHLCs');
    };
};

subtest 'prepare ohlc minute' => sub {
    subtest 'Minutely' => sub {
        my @minutely = ({
                date  => '2012-07-09 00:12:00',
                quote => 79.5185,
                bid   => 79.5185,
                ask   => 79.5185
            },
            {
                date  => '2012-07-09 00:12:10',
                quote => 79.5225,
                bid   => 79.5225,
                ask   => 79.5225
            },
            {
                date  => '2012-07-09 00:12:20',
                quote => 79.5119,
                bid   => 79.5119,
                ask   => 79.5119
            },
            {
                date  => '2012-07-09 00:12:40',
                quote => 79.5164,
                bid   => 79.5164,
                ask   => 79.5164
            },

            {
                date  => '2012-07-09 00:13:00',
                quote => 79.5175,
                bid   => 79.5175,
                ask   => 79.5175
            },
            {
                date  => '2012-07-09 00:13:10',
                quote => 79.5254,
                bid   => 79.5254,
                ask   => 79.5254
            },
            {
                date  => '2012-07-09 00:13:20',
                quote => 79.516,
                bid   => 79.516,
                ask   => 79.516
            },
            {
                date  => '2012-07-09 00:13:40',
                quote => 79.5172,
                bid   => 79.5172,
                ask   => 79.5172
            },

            {
                date  => '2012-07-09 00:14:00',
                quote => 79.5181,
                bid   => 79.5181,
                ask   => 79.5181
            },
            {
                date  => '2012-07-09 00:14:10',
                quote => 79.5237,
                bid   => 79.5237,
                ask   => 79.5237
            },
            {
                date  => '2012-07-09 00:14:20',
                quote => 79.5143,
                bid   => 79.5143,
                ask   => 79.5143
            },
            {
                date  => '2012-07-09 00:14:40',
                quote => 79.5144,
                bid   => 79.5144,
                ask   => 79.5144
            },

            {
                date  => '2012-07-09 00:15:00',
                quote => 79.5143,
                bid   => 79.5143,
                ask   => 79.5143
            },
            {
                date  => '2012-07-09 00:15:10',
                quote => 79.5285,
                bid   => 79.5285,
                ask   => 79.5285
            },
            {
                date  => '2012-07-09 00:15:20',
                quote => 79.5143,
                bid   => 79.5143,
                ask   => 79.5143
            },
            {
                date  => '2012-07-09 00:15:40',
                quote => 79.5256,
                bid   => 79.5256,
                ask   => 79.5256
            },

            {
                date  => '2012-07-09 00:16:00',
                quote => 79.5255,
                bid   => 79.5255,
                ask   => 79.5255
            },
            {
                date  => '2012-07-09 00:16:10',
                quote => 79.5588,
                bid   => 79.5588,
                ask   => 79.5588
            },
            {
                date  => '2012-07-09 00:16:20',
                quote => 79.5244,
                bid   => 79.5244,
                ask   => 79.5244
            },
            {
                date  => '2012-07-09 00:16:40',
                quote => 79.5386,
                bid   => 79.5386,
                ask   => 79.5386
            },

            {
                date  => '2012-07-09 00:17:00',
                quote => 79.5346,
                bid   => 79.5346,
                ask   => 79.5346
            },
            {
                date  => '2012-07-09 00:17:10',
                quote => 79.5398,
                bid   => 79.5398,
                ask   => 79.5398
            },
            {
                date  => '2012-07-09 00:17:20',
                quote => 79.5305,
                bid   => 79.5305,
                ask   => 79.5305
            },
            {
                date  => '2012-07-09 00:17:40',
                quote => 79.5355,
                bid   => 79.5355,
                ask   => 79.5355
            },

            {
                date  => '2012-07-09 00:18:00',
                quote => 79.5365,
                bid   => 79.5365,
                ask   => 79.5365
            },
            {
                date  => '2012-07-09 00:18:10',
                quote => 79.5495,
                bid   => 79.5495,
                ask   => 79.5495
            },
            {
                date  => '2012-07-09 00:18:20',
                quote => 79.5351,
                bid   => 79.5351,
                ask   => 79.5351
            },
            {
                date  => '2012-07-09 00:18:40',
                quote => 79.5359,
                bid   => 79.5359,
                ask   => 79.5359
            },

            {
                date  => '2012-07-09 00:19:00',
                quote => 79.5361,
                bid   => 79.5361,
                ask   => 79.5361
            },
            {
                date  => '2012-07-09 00:19:10',
                quote => 79.5538,
                bid   => 79.5538,
                ask   => 79.5538
            },
            {
                date  => '2012-07-09 00:19:20',
                quote => 79.5304,
                bid   => 79.5304,
                ask   => 79.5304
            },
            {
                date  => '2012-07-09 00:19:40',
                quote => 79.5355,
                bid   => 79.5355,
                ask   => 79.5355
            },

            {
                date  => '2012-07-09 00:20:00',
                quote => 79.5352,
                bid   => 79.5352,
                ask   => 79.5352
            },
            {
                date  => '2012-07-09 00:20:10',
                quote => 79.5423,
                bid   => 79.5423,
                ask   => 79.5423
            },
            {
                date  => '2012-07-09 00:20:20',
                quote => 79.5327,
                bid   => 79.5327,
                ask   => 79.5327
            },
            {
                date  => '2012-07-09 00:20:40',
                quote => 79.5345,
                bid   => 79.5345,
                ask   => 79.5345
            },

            {
                date  => '2012-07-09 00:21:00',
                quote => 79.5355,
                bid   => 79.5355,
                ask   => 79.5355
            },
            {
                date  => '2012-07-09 00:21:10',
                quote => 79.5414,
                bid   => 79.5414,
                ask   => 79.5414
            },
            {
                date  => '2012-07-09 00:21:20',
                quote => 79.5209,
                bid   => 79.5209,
                ask   => 79.5209
            },
            {
                date  => '2012-07-09 00:21:40',
                quote => 79.5285,
                bid   => 79.5285,
                ask   => 79.5285
            },

            {
                date  => '2012-07-10 13:40:40',
                quote => 79.5285,
                bid   => 79.5285,
                ask   => 79.5285
            },

        );

        foreach my $ohlc (@minutely) {
            lives_ok {
                BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
                    epoch      => Date::Parse::str2time($ohlc->{date}),
                    quote      => $ohlc->{quote},
                    bid        => $ohlc->{bid},
                    ask        => $ohlc->{ask},
                    underlying => 'frxUSDJPY'
                });
            }
            'for ohlc daily - ' . $ohlc->{date};
        }

    };
};

subtest 'Minutely - Start-End - Simple' => sub {
    my $api = Postgres::FeedDB::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);
    my $ohlcs;
    my $start_time = '2012-07-09 00:00:00';
    my $end_time   = '2012-07-09 23:00:00';

    subtest 'There is no official / unofficial for OHLC minute' => sub {
        $ohlcs = $api->ohlc_start_end({
            start_time         => $start_time,
            end_time           => $end_time,
            aggregation_period => 60,
        });
        is scalar @$ohlcs, 10, 'All in all 10 ticks found';

        subtest 'OHLC data check' => sub {
            my $ohlc = $ohlcs->[0];
            is $ohlc->epoch, Date::Utility->new('2012-07-09 00:21:00')->epoch, 'epoch ok';
            is $ohlc->open,  79.5355, 'open ok';
            is $ohlc->high,  79.5414, 'high ok';
            is $ohlc->low,   79.5209, 'low ok';
            is $ohlc->close, 79.5285, 'close ok';

            $ohlc = $ohlcs->[1];
            is $ohlc->epoch, Date::Utility->new('2012-07-09 00:20:00')->epoch, 'epoch ok';
            is $ohlc->open,  79.5352, 'open ok';
            is $ohlc->high,  79.5423, 'high ok';
            is $ohlc->low,   79.5327, 'low ok';
            is $ohlc->close, 79.5345, 'close ok';

            $ohlc = $ohlcs->[9];
            is $ohlc->epoch, Date::Utility->new('2012-07-09 00:12:00')->epoch, 'epoch ok';
            is $ohlc->open,  79.5185, 'open ok';
            is $ohlc->high,  79.5225, 'high ok';
            is $ohlc->low,   79.5119, 'low ok';
            is $ohlc->close, 79.5164, 'close ok';
        };

        my $unofficial = $api->ohlc_start_end({
            start_time         => $start_time,
            end_time           => $end_time,
            aggregation_period => 60,
            official           => undef,
        });
        is_deeply($unofficial, $ohlcs, 'check OHLCs minute - 1');

        my $official = $api->ohlc_start_end({
            start_time         => $start_time,
            end_time           => $end_time,
            aggregation_period => 60,
            official           => 1,
        });
        is_deeply($official, $ohlcs, 'check OHLCs minute - 2');
    };

    subtest 'Access through Underlying' => sub {
        my $underlying       = BOM::Market::Underlying->new('frxUSDJPY');
        my $ohlcs_underlying = $underlying->ohlc_between_start_end({
            start_time         => $start_time,
            end_time           => $end_time,
            aggregation_period => 60,
        });
        is_deeply($ohlcs_underlying, $ohlcs, 'check unofficial OHLCs [Default]');

        $ohlcs_underlying = $underlying->ohlc_between_start_end({
            start_time         => $start_time,
            end_time           => $end_time,
            aggregation_period => 60,
        });
        is_deeply($ohlcs_underlying, $ohlcs, 'check unofficial OHLCs');

        $ohlcs_underlying = $underlying->ohlc_between_start_end({
            start_time         => $start_time,
            end_time           => $end_time,
            aggregation_period => 60,
        });
        is_deeply($ohlcs_underlying, $ohlcs, 'check official OHLCs');
    };
};

done_testing;
