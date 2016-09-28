#!/etc/rmg/bin/perl

use strict;
use warnings;
use utf8;
use Test::More 0.22 tests => 5;
use Test::Exception;
use Test::Warn;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

use Quant::Framework::Spot::DatabaseAPI;
use Quant::Framework::Spot::OHLC;
use DateTime;
use Date::Utility;

my $dbh = BOM::Database::FeedDB::read_dbh;
$dbh->{RaiseError} = 1;

subtest 'Preparing records' => sub {

    lives_ok {
        my $date = DateTime->new(
            year   => 2012,
            month  => 5,
            day    => 13,
            hour   => 5,
            minute => 10,
            second => 1
        );
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch => $date->epoch,
            quote => 79.873,
            bid   => 100.2,
            ask   => 100.4
        });
    }
    'Tick 1 - 2012-05-13 05:10:01';

    lives_ok {
        my $date = DateTime->new(
            year   => 2012,
            month  => 5,
            day    => 14,
            hour   => 5,
            minute => 10,
            second => 1
        );
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch => $date->epoch,
            quote => 79.815,
            bid   => 100.2,
            ask   => 100.4
        });
    }
    'Tick 2 - 2012-05-14 05:10:01';

    lives_ok {
        my $date = DateTime->new(
            year   => 2012,
            month  => 5,
            day    => 14,
            hour   => 6,
            minute => 10,
            second => 1
        );
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch => $date->epoch,
            quote => 80.349,
            bid   => 100.2,
            ask   => 100.4
        });
    }
    'Tick 3 - 2012-05-14 06:10:01';

    lives_ok {
        my $date = DateTime->new(
            year   => 2012,
            month  => 5,
            day    => 14,
            hour   => 7,
            minute => 10,
            second => 1
        );
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch => $date->epoch,
            quote => 80.314,
            bid   => 100.2,
            ask   => 100.4
        });
    }
    'Tick 4 - 2012-05-14 07:10:01';

    my @daily = (
        ['2012-05-16', 80.313, 80.554, 80.203, 80.371],
        ['2012-05-17', 80.364, 80.381, 79.138, 79.422],
        ['2012-05-18', 79.419, 79.473, 78.999, 79.017],
    );

    for my $ohlc (@daily) {
        my ($date, $open, $high, $low, $close) = @$ohlc;
        $date = Date::Utility->new($date);

        lives_ok {
            BOM::Test::Data::Utility::FeedTestDatabase::create_ohlc_daily({
                epoch => $date->epoch,
                open  => $open,
                high  => $high,
                low   => $low,
                close => $close
            });
        }
        'Daily Non-Official ' . $date->date_yyyymmdd;
    }
};

subtest 'Simple OHLC fetch' => sub {
    my $api = Quant::Framework::Spot::DatabaseAPI->new(
        underlying        => 'frxUSDJPY',
        use_official_ohlc => 1,
        db_handle         => $dbh,
    );

    subtest 'from ohlc only' => sub {
        my $data = $api->ohlc_daily_list({
            start_time => '2012-05-16 00:00:00',
            end_time   => '2012-05-18 23:59:59'
        });
        ok $data, 'Got Some output';
        is scalar @{$data}, 3, 'Got 3 ohlc';

        my $date = Date::Utility->new({epoch => $data->[0]->epoch})->datetime_yyyymmdd_hhmmss;
        is $date, '2012-05-16 00:00:00', 'Day 16';
        is $data->[0]->open,  80.313, 'Correct open';
        is $data->[0]->high,  80.554, 'Correct high';
        is $data->[0]->low,   80.203, 'Correct low';
        is $data->[0]->close, 80.371, 'Correct close';

        $date = Date::Utility->new({epoch => $data->[1]->epoch})->datetime_yyyymmdd_hhmmss;
        is $date, '2012-05-17 00:00:00', 'Day 17';
        is $data->[1]->open,  80.364, 'Correct open';
        is $data->[1]->high,  80.381, 'Correct high';
        is $data->[1]->low,   79.138, 'Correct low';
        is $data->[1]->close, 79.422, 'Correct close';

        $date = Date::Utility->new({epoch => $data->[2]->epoch})->datetime_yyyymmdd_hhmmss;
        is $date, '2012-05-18 00:00:00', 'Day 18';
        is $data->[2]->open,  79.419, 'Correct open';
        is $data->[2]->high,  79.473, 'Correct high';
        is $data->[2]->low,   78.999, 'Correct low';
        is $data->[2]->close, 79.017, 'Correct close';
    };

    subtest 'Scurry from ticks' => sub {
        my $data = $api->ohlc_daily_list({
            start_time => '2012-05-14 01:00:00',
            end_time   => '2012-05-14 23:59:59'
        });
        ok $data, 'Got Some output';
        is scalar @{$data}, 1, 'Got 1 ohlc';

        my $date = Date::Utility->new({epoch => $data->[0]->epoch})->datetime_yyyymmdd_hhmmss;
        is $date, '2012-05-14 00:00:00', 'Day 15';
        is $data->[0]->open,  79.815, 'Correct open';
        is $data->[0]->high,  80.349, 'Correct low';
        is $data->[0]->low,   79.815, 'Correct high';
        is $data->[0]->close, 80.314, 'Correct close';
    };

    subtest 'Combination of the two' => sub {
        my $data = $api->ohlc_daily_list({
            start_time => '2012-05-14 01:00:00',
            end_time   => '2012-05-18 23:59:59',
            official   => 1
        });
        ok $data, 'Got Some output';
        is scalar @{$data}, 4, 'Got 4 ohlc';

        my $date = Date::Utility->new({epoch => $data->[0]->epoch})->datetime_yyyymmdd_hhmmss;
        is $date, '2012-05-14 00:00:00', 'Day 15';
        is $data->[0]->open,  79.815, 'Correct open';
        is $data->[0]->high,  80.349, 'Correct low';
        is $data->[0]->low,   79.815, 'Correct high';
        is $data->[0]->close, 80.314, 'Correct close';

        $date = Date::Utility->new({epoch => $data->[1]->epoch})->datetime_yyyymmdd_hhmmss;
        is $date, '2012-05-16 00:00:00', 'Day 16';
        is $data->[1]->open,  80.313, 'Correct open';
        is $data->[1]->high,  80.554, 'Correct high';
        is $data->[1]->low,   80.203, 'Correct low';
        is $data->[1]->close, 80.371, 'Correct close';

        $date = Date::Utility->new({epoch => $data->[2]->epoch})->datetime_yyyymmdd_hhmmss;
        is $date, '2012-05-17 00:00:00', 'Day 17';
        is $data->[2]->open,  80.364, 'Correct open';
        is $data->[2]->high,  80.381, 'Correct high';
        is $data->[2]->low,   79.138, 'Correct low';
        is $data->[2]->close, 79.422, 'Correct close';

        $date = Date::Utility->new({epoch => $data->[3]->epoch})->datetime_yyyymmdd_hhmmss;
        is $date, '2012-05-18 00:00:00', 'Day 18';
        is $data->[3]->open,  79.419, 'Correct open';
        is $data->[3]->high,  79.473, 'Correct high';
        is $data->[3]->low,   78.999, 'Correct low';
        is $data->[3]->close, 79.017, 'Correct close';
    };
};

subtest 'Testing selection when both are present' => sub {
    my $api = Quant::Framework::Spot::DatabaseAPI->new(
        underlying        => 'frxUSDJPY',
        use_official_ohlc => 1,
        db_handle         => $dbh,
    );

    my $data = $api->ohlc_daily_list({
        start_time => '2012-05-14 06:00:00',
        end_time   => '2012-05-18 23:59:59'
    });
    ok $data, 'Got Some output';
    is scalar @{$data}, 4, 'Got 4 ohlc';

    my $date = Date::Utility->new({epoch => $data->[0]->epoch})->datetime_yyyymmdd_hhmmss;
    is $date, '2012-05-14 00:00:00', 'Day 15';
    is $data->[0]->open,  80.349, 'Correct open';
    is $data->[0]->high,  80.349, 'Correct high';
    is $data->[0]->low,   80.314, 'Correct low';
    is $data->[0]->close, 80.314, 'Correct close';

    $date = Date::Utility->new({epoch => $data->[1]->epoch})->datetime_yyyymmdd_hhmmss;
    is $date, '2012-05-16 00:00:00', 'Day 16';
    is $data->[1]->open,  80.313, 'Correct open';
    is $data->[1]->high,  80.554, 'Correct high';
    is $data->[1]->low,   80.203, 'Correct low';
    is $data->[1]->close, 80.371, 'Correct close';

    $date = Date::Utility->new({epoch => $data->[2]->epoch})->datetime_yyyymmdd_hhmmss;
    is $date, '2012-05-17 00:00:00', 'Day 17';
    is $data->[2]->open,  80.364, 'Correct open';
    is $data->[2]->high,  80.381, 'Correct high';
    is $data->[2]->low,   79.138, 'Correct low';
    is $data->[2]->close, 79.422, 'Correct close';

    $date = Date::Utility->new({epoch => $data->[3]->epoch})->datetime_yyyymmdd_hhmmss;
    is $date, '2012-05-18 00:00:00', 'Day 18';
    is $data->[3]->open,  79.419, 'Correct open';
    is $data->[3]->high,  79.473, 'Correct high';
    is $data->[3]->low,   78.999, 'Correct low';
    is $data->[3]->close, 79.017, 'Correct close';
};

subtest 'Tail End ticks' => sub {
    my $api = Quant::Framework::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);
    my $official_api = Quant::Framework::Spot::DatabaseAPI->new(
        underlying        => 'frxUSDJPY',
        use_official_ohlc => 1,
        db_handle         => $dbh,
    );

    subtest 'Preparing ticks' => sub {
        lives_ok {
            my $date = DateTime->new(
                year   => 2012,
                month  => 5,
                day    => 19,
                hour   => 5,
                minute => 10,
                second => 1
            );
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
                epoch => $date->epoch,
                quote => 80.313,
            });
        }
        'Tick 9 - 2012-05-19 05:10:01';

        lives_ok {
            my $date = DateTime->new(
                year   => 2012,
                month  => 5,
                day    => 19,
                hour   => 6,
                minute => 10,
                second => 1
            );
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
                epoch => $date->epoch,
                quote => 80.554,
            });
        }
        'Tick 10 - 2012-05-19 06:10:01';

        lives_ok {
            my $date = DateTime->new(
                year   => 2012,
                month  => 5,
                day    => 19,
                hour   => 7,
                minute => 10,
                second => 1
            );
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
                epoch => $date->epoch,
                quote => 80.203,
            });
        }
        'Tick 11 - 2012-05-19 07:10:01';

        lives_ok {
            my $date = DateTime->new(
                year   => 2012,
                month  => 5,
                day    => 19,
                hour   => 8,
                minute => 10,
                second => 1
            );
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
                epoch => $date->epoch,
                quote => 80.371,
            });
        }
        'Tick 12 - 2012-05-19 07:10:01';
    };

    subtest 'Scurry from ticks' => sub {
        my $data = $api->ohlc_daily_list({
            start_time => '2012-05-19 01:00:00',
            end_time   => '2012-05-19 23:59:59'
        });
        ok $data, 'Got Some output';
        is scalar @{$data}, 1, 'Got 1 ohlc';

        my $date = Date::Utility->new({epoch => $data->[0]->epoch})->datetime_yyyymmdd_hhmmss;
        is $date, '2012-05-19 00:00:00', 'Day 19';
        is $data->[0]->open,  80.313, 'Correct open';
        is $data->[0]->high,  80.554, 'Correct low';
        is $data->[0]->low,   80.203, 'Correct high';
        is $data->[0]->close, 80.371, 'Correct close';
    };

    subtest 'Combination' => sub {
        my $data = $official_api->ohlc_daily_list({
            start_time => '2012-05-16 00:00:00',
            end_time   => '2012-05-19 23:00:00'
        });
        ok $data, 'Got Some output';
        is scalar @{$data}, 4, 'Got 4 ohlc';

        my $date = Date::Utility->new({epoch => $data->[0]->epoch})->datetime_yyyymmdd_hhmmss;
        is $date, '2012-05-16 00:00:00', 'Day 16';
        is $data->[0]->open,  80.313, 'Correct open';
        is $data->[0]->high,  80.554, 'Correct high';
        is $data->[0]->low,   80.203, 'Correct low';
        is $data->[0]->close, 80.371, 'Correct close';

        $date = Date::Utility->new({epoch => $data->[1]->epoch})->datetime_yyyymmdd_hhmmss;
        is $date, '2012-05-17 00:00:00', 'Day 17';
        is $data->[1]->open,  80.364, 'Correct open';
        is $data->[1]->high,  80.381, 'Correct high';
        is $data->[1]->low,   79.138, 'Correct low';
        is $data->[1]->close, 79.422, 'Correct close';

        $date = Date::Utility->new({epoch => $data->[2]->epoch})->datetime_yyyymmdd_hhmmss;
        is $date, '2012-05-18 00:00:00', 'Day 18';
        is $data->[2]->open,  79.419, 'Correct open';
        is $data->[2]->high,  79.473, 'Correct high';
        is $data->[2]->low,   78.999, 'Correct low';
        is $data->[2]->close, 79.017, 'Correct close';

        $date = Date::Utility->new({epoch => $data->[3]->epoch})->datetime_yyyymmdd_hhmmss;
        is $date, '2012-05-19 00:00:00', 'Day 19';
        is $data->[3]->open,  80.313, 'Correct open';
        is $data->[3]->high,  80.554, 'Correct low';
        is $data->[3]->low,   80.203, 'Correct high';
        is $data->[3]->close, 80.371, 'Correct close';
    };
};

subtest 'Non Official OHLC' => sub {
    my $api = Quant::Framework::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);

    subtest 'One OHLC Data' => sub {
        my $data = $api->ohlc_daily_list({
            start_time => '2012-05-14 01:00:00',
            end_time   => '2012-05-18 23:59:59'
        });
        ok $data, 'Got Some output';
        is scalar @{$data}, 1, 'Got 1 ohlc';

        my $date = Date::Utility->new({epoch => $data->[0]->epoch})->datetime_yyyymmdd_hhmmss;
        is $date, '2012-05-14 00:00:00', 'Day 14';
        is $data->[0]->open,  79.815, 'Correct open';
        is $data->[0]->high,  80.349, 'Correct low';
        is $data->[0]->low,   79.815, 'Correct high';
        is $data->[0]->close, 80.314, 'Correct close';
    };
};
