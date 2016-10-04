use Test::Most;
use utf8;
use Test::FailWarnings;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);
use Date::Parse;
use DateTime;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );
use Postgres::FeedDB::Spot::DatabaseAPI;
use Postgres::FeedDB::Spot::OHLC;
use BOM::Market::Underlying;
use Date::Utility;

use Postgres::FeedDB::Spot::DatabaseAPI;
my $dbh = Postgres::FeedDB::read_dbh;
$dbh->{RaiseError} = 1;

subtest 'prepare ticks' => sub {
    lives_ok {
        my $date = DateTime->new(
            year   => 2012,
            month  => 5,
            day    => 15,
            hour   => 12,
            minute => 12,
            second => 1
        );
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch => $date->epoch,
            quote => 100.1,
            bid   => 100.2,
            ask   => 100.4
        });
    }
    'Tick 1 - 2012-05-15 12:12:01';

    lives_ok {
        my $date = DateTime->new(
            year   => 2012,
            month  => 5,
            day    => 16,
            hour   => 12,
            minute => 12,
            second => 1
        );
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch => $date->epoch,
            quote => 101.1,
            bid   => 101.8,
            ask   => 101.0
        });
    }
    'Tick 2 - 2012-05-16 12:12:01';

    lives_ok {
        my $date = DateTime->new(
            year  => 2012,
            month => 5,
            day   => 16,
            hour  => 16
        );
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch => $date->epoch,
            quote => 101.3,
            bid   => 101.5,
            ask   => 101.1
        });
    }
    'Tick 3 - 2012-05-16 16:00:00';

    lives_ok {
        my $date = DateTime->new(
            year  => 2012,
            month => 5,
            day   => 16,
            hour  => 19
        );
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch => $date->epoch,
            quote => 101.1,
            bid   => 101.3,
            ask   => 101.1
        });
    }
    'Tick 4 - 2012-05-16 19:00:00';

    lives_ok {
        my $date = DateTime->new(
            year  => 2012,
            month => 5,
            day   => 17,
            hour  => 15
        );
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch => $date->epoch,
            quote => 98.9,
            bid   => 100.8,
            ask   => 98.0
        });
    }
    'Tick 5 - 2012-05-17 15:00:00';

    lives_ok {
        my $date = DateTime->new(
            year  => 2012,
            month => 5,
            day   => 18,
            hour  => 11
        );
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch => $date->epoch,
            quote => 95.2,
            bid   => 93.0,
            ask   => 96.5
        });
    }
    'Tick 6 - 2012-05-18 11:00:00';

    lives_ok {
        my $date = DateTime->new(
            year  => 2012,
            month => 5,
            day   => 18,
            hour  => 17
        );
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch => $date->epoch,
            quote => 93.6,
            bid   => 93.7,
            ask   => 90.2
        });
    }
    'Tick 7 - 2012-05-18 17:00:00';

    lives_ok {
        my $date = DateTime->new(
            year  => 2012,
            month => 5,
            day   => 19,
            hour  => 12
        );
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch => $date->epoch,
            quote => 93.8,
            bid   => 94.2,
            ask   => 91.4
        });
    }
    'Tick 8 - 2012-05-19 12:00:00';

    lives_ok {
        my $date = DateTime->new(
            year  => 2012,
            month => 5,
            day   => 20,
            hour  => 14
        );
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch => $date->epoch,
            quote => 92.6,
            bid   => 93.5,
            ask   => 90.2
        });
    }
    'Tick 9 - 2012-05-20 14:00:00';

    lives_ok {
        my $date = DateTime->new(
            year  => 2012,
            month => 5,
            day   => 20,
            hour  => 14
        );
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'frxUSDAUD',
            epoch      => $date->epoch,
            quote      => 1.1,
            bid        => 1.12,
            ask        => 1.08
        });
    }
    'Tick 10 - frxUSDAUD 2012-05-20 14:00:00';
};

subtest 'Tick Fetch - Start-End-limit' => sub {
    my $api = Postgres::FeedDB::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);

    my $ticks = $api->ticks_start_end_with_limit_for_charting({
        start_time => '2012-05-15 00:00:00',
        end_time   => '2012-05-20 23:00:00',
        limit      => 5,
    });
    isa_ok $ticks, 'ARRAY', 'Got ticks for 2012-05-15 00:00:00 to 2012-05-20 23:00:00 (limit 5)';
    is scalar @$ticks, 5, 'All in all 5 ticks found';

    subtest 'Tick datatype' => sub {
        foreach my $tick (@$ticks) {
            my $date = Date::Utility->new({epoch => $tick->epoch});
            isa_ok $tick, 'Postgres::FeedDB::Spot::Tick', $date->datetime_yyyymmdd_hhmmss;
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

    subtest 'No frxUSDAUD' => sub {
        foreach my $tick (@$ticks) {
            my $date = Date::Utility->new({epoch => $tick->epoch});
            ok $tick->quote > 2, 'Tick at ' . $date->datetime_yyyymmdd_hhmmss . ' is frxUSDJPY';
        }
    };

    subtest 'epoch match' => sub {
        is $ticks->[0]->epoch,
            DateTime->new(
            year  => 2012,
            month => 5,
            day   => 20,
            hour  => 14
            )->epoch, 'epoch match';
        is $ticks->[1]->epoch,
            DateTime->new(
            year  => 2012,
            month => 5,
            day   => 19,
            hour  => 12
            )->epoch, 'epoch match';
        is $ticks->[2]->epoch,
            DateTime->new(
            year  => 2012,
            month => 5,
            day   => 18,
            hour  => 17
            )->epoch, 'epoch match';
        is $ticks->[3]->epoch,
            DateTime->new(
            year  => 2012,
            month => 5,
            day   => 18,
            hour  => 11
            )->epoch, 'epoch match';
        is $ticks->[4]->epoch,
            DateTime->new(
            year  => 2012,
            month => 5,
            day   => 17,
            hour  => 15
            )->epoch, 'epoch match';
    };
};

my ($ticks, $ticks_2);
my $start_time = '2012-05-15 00:00:00';
my $end_time   = '2012-05-16 19:00:00';

subtest 'Tick Fetch - Start-End-limit (Big limit)' => sub {
    my $api = Postgres::FeedDB::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);

    my $end_epoch = Date::Utility->new($end_time)->epoch;

    $ticks = $api->ticks_start_end_with_limit_for_charting({
        start_time => $start_time,
        end_time   => $end_time,
        limit      => 1000,
    });
    isa_ok $ticks, 'ARRAY', "Got ticks for 2012-05-15 00:00:00 to $end_time and";
    is scalar @$ticks, 4, '4 ticks found, we are almost there';

    subtest 'Tick Quality' => sub {
        foreach my $tick (@$ticks) {
            my $date = Date::Utility->new({epoch => $tick->epoch});
            ok $tick->epoch <= $end_epoch, 'Tick ' . $date->datetime_yyyymmdd_hhmmss . ' <= 2012-05-16 19:00:00';
        }
    };

    is $ticks->[0]->epoch, $end_epoch, 'first OHLC time match';
};

subtest 'Access through Underlying' => sub {
    my $underlying = BOM::Market::Underlying->new('frxUSDJPY');

    $ticks_2 = $underlying->feed_api->ticks_start_end_with_limit_for_charting({
        start_time => $start_time,
        end_time   => $end_time,
        limit      => 1000,
    });
    is_deeply($ticks, $ticks_2, 'Access from Underlying feed api, ticks match');
};

subtest 'prepare ohlc daily' => sub {
    my @ohlc_daily = (

        {
            date  => '2012-05-28 01:00:00',
            quote => 101.7,
            bid   => 101.7,
            ask   => 101.7
        },
        {
            date  => '2012-05-28 04:00:10',
            quote => 104.2,
            bid   => 104.2,
            ask   => 104.2
        },
        {
            date  => '2012-05-28 09:00:20',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },
        {
            date  => '2012-05-28 15:00:40',
            quote => 103.2,
            bid   => 103.2,
            ask   => 103.2
        },

        {
            date  => '2012-05-29 01:00:00',
            quote => 97.8,
            bid   => 97.8,
            ask   => 97.8
        },
        {
            date  => '2012-05-29 04:00:10',
            quote => 100.2,
            bid   => 100.2,
            ask   => 100.2
        },
        {
            date  => '2012-05-29 09:00:20',
            quote => 96.4,
            bid   => 96.4,
            ask   => 96.4
        },
        {
            date  => '2012-05-29 15:00:40',
            quote => 97.2,
            bid   => 97.2,
            ask   => 97.2
        },

        {
            date  => '2012-05-30 01:00:00',
            quote => 98.2,
            bid   => 98.2,
            ask   => 98.2
        },
        {
            date  => '2012-05-30 04:00:10',
            quote => 100.2,
            bid   => 100.2,
            ask   => 100.2
        },
        {
            date  => '2012-05-30 09:00:20',
            quote => 98.2,
            bid   => 98.2,
            ask   => 98.2
        },
        {
            date  => '2012-05-30 15:00:40',
            quote => 99.7,
            bid   => 99.7,
            ask   => 99.7
        },

        {
            date  => '2012-05-31 01:00:00',
            quote => 98.2,
            bid   => 98.2,
            ask   => 98.2
        },
        {
            date  => '2012-05-31 04:00:10',
            quote => 100.2,
            bid   => 100.2,
            ask   => 100.2
        },
        {
            date  => '2012-05-31 09:00:20',
            quote => 98.2,
            bid   => 98.2,
            ask   => 98.2
        },
        {
            date  => '2012-05-31 15:00:40',
            quote => 99.7,
            bid   => 99.7,
            ask   => 99.7
        },

        {
            date  => '2012-06-01 01:00:00',
            quote => 100.1,
            bid   => 100.1,
            ask   => 100.1
        },
        {
            date  => '2012-06-01 04:00:10',
            quote => 101.4,
            bid   => 101.4,
            ask   => 101.4
        },
        {
            date  => '2012-06-01 09:00:20',
            quote => 100.1,
            bid   => 100.1,
            ask   => 100.1
        },
        {
            date  => '2012-06-01 15:00:40',
            quote => 101.3,
            bid   => 101.3,
            ask   => 101.3
        },

        {
            date  => '2012-06-02 01:00:00',
            quote => 99.1,
            bid   => 99.1,
            ask   => 99.1
        },
        {
            date  => '2012-06-02 04:00:10',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },
        {
            date  => '2012-06-02 09:00:20',
            quote => 99.1,
            bid   => 99.1,
            ask   => 99.1
        },
        {
            date  => '2012-06-02 15:00:40',
            quote => 100.2,
            bid   => 100.2,
            ask   => 100.2
        },

        {
            date  => '2012-06-03 01:00:00',
            quote => 100.1,
            bid   => 100.1,
            ask   => 100.1
        },
        {
            date  => '2012-06-03 04:00:10',
            quote => 101.4,
            bid   => 101.4,
            ask   => 101.4
        },
        {
            date  => '2012-06-03 09:00:20',
            quote => 100.1,
            bid   => 100.1,
            ask   => 100.1
        },
        {
            date  => '2012-06-03 15:00:40',
            quote => 101.3,
            bid   => 101.3,
            ask   => 101.3
        },

        {
            date  => '2012-06-04 01:00:00',
            quote => 100.9,
            bid   => 100.9,
            ask   => 100.9
        },
        {
            date  => '2012-06-04 04:00:10',
            quote => 100.9,
            bid   => 100.9,
            ask   => 100.9
        },
        {
            date  => '2012-06-04 09:00:20',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },
        {
            date  => '2012-06-04 15:00:40',
            quote => 100.2,
            bid   => 100.2,
            ask   => 100.2
        },

        {
            date  => '2012-06-05 01:00:00',
            quote => 100.5,
            bid   => 100.5,
            ask   => 100.5
        },
        {
            date  => '2012-06-05 04:00:10',
            quote => 101.2,
            bid   => 101.2,
            ask   => 101.2
        },
        {
            date  => '2012-06-05 09:00:20',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },
        {
            date  => '2012-06-05 15:00:40',
            quote => 101.1,
            bid   => 101.1,
            ask   => 101.1
        },

        {
            date  => '2012-06-07 01:00:00',
            quote => 100.3,
            bid   => 100.3,
            ask   => 100.3
        },
        {
            date  => '2012-06-07 04:00:10',
            quote => 105.2,
            bid   => 105.2,
            ask   => 105.2
        },
        {
            date  => '2012-06-07 09:00:20',
            quote => 100.3,
            bid   => 100.3,
            ask   => 100.3
        },
        {
            date  => '2012-06-07 15:00:40',
            quote => 103.1,
            bid   => 103.1,
            ask   => 103.1
        },

        {
            date  => '2012-06-09 01:00:00',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },
        {
            date  => '2012-06-09 04:00:10',
            quote => 105.5,
            bid   => 105.5,
            ask   => 105.5
        },
        {
            date  => '2012-06-09 09:00:20',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },
        {
            date  => '2012-06-09 15:00:40',
            quote => 101.7,
            bid   => 101.7,
            ask   => 101.7
        },

        {
            date  => '2012-06-10 01:00:00',
            quote => 99.9,
            bid   => 99.9,
            ask   => 99.9
        },
        {
            date  => '2012-06-10 04:00:10',
            quote => 100.2,
            bid   => 100.2,
            ask   => 100.2
        },
        {
            date  => '2012-06-10 09:00:20',
            quote => 99.1,
            bid   => 99.1,
            ask   => 99.1
        },
        {
            date  => '2012-06-10 15:00:40',
            quote => 99.1,
            bid   => 99.1,
            ask   => 99.1
        },

        {
            date  => '2012-06-12 01:00:00',
            quote => 100.2,
            bid   => 100.2,
            ask   => 100.2
        },
        {
            date  => '2012-06-12 04:00:10',
            quote => 100.2,
            bid   => 100.2,
            ask   => 100.2
        },
        {
            date  => '2012-06-12 09:00:20',
            quote => 100.1,
            bid   => 100.1,
            ask   => 100.1
        },
        {
            date  => '2012-06-12 15:00:40',
            quote => 100.1,
            bid   => 100.1,
            ask   => 100.1
        },

        {
            date  => '2012-06-14 01:00:00',
            quote => 100.7,
            bid   => 100.7,
            ask   => 100.7
        },
        {
            date  => '2012-06-14 04:00:10',
            quote => 100.9,
            bid   => 100.9,
            ask   => 100.9
        },
        {
            date  => '2012-06-14 09:00:20',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },
        {
            date  => '2012-06-14 15:00:40',
            quote => 100.5,
            bid   => 100.5,
            ask   => 100.5
        },

        {
            date  => '2012-06-16 01:00:00',
            quote => 101.9,
            bid   => 101.9,
            ask   => 101.9
        },
        {
            date  => '2012-06-16 04:00:10',
            quote => 102.2,
            bid   => 102.2,
            ask   => 102.2
        },
        {
            date  => '2012-06-16 09:00:20',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },
        {
            date  => '2012-06-16 15:00:40',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },

        {
            date  => '2012-06-18 01:00:00',
            quote => 98.4,
            bid   => 98.4,
            ask   => 98.4
        },
        {
            date  => '2012-06-18 04:00:10',
            quote => 100.2,
            bid   => 100.2,
            ask   => 100.2
        },
        {
            date  => '2012-06-18 09:00:20',
            quote => 97.2,
            bid   => 97.2,
            ask   => 97.2
        },
        {
            date  => '2012-06-18 15:00:40',
            quote => 99.5,
            bid   => 99.5,
            ask   => 99.5
        },

        {
            date  => '2012-06-20 01:00:00',
            quote => 99.2,
            bid   => 99.2,
            ask   => 99.2
        },
        {
            date  => '2012-06-20 04:00:10',
            quote => 100.2,
            bid   => 100.2,
            ask   => 100.2
        },
        {
            date  => '2012-06-20 09:00:20',
            quote => 99.2,
            bid   => 99.2,
            ask   => 99.2
        },
        {
            date  => '2012-06-20 15:00:40',
            quote => 99.8,
            bid   => 99.8,
            ask   => 99.8
        },

        {
            date  => '2012-06-22 01:00:00',
            quote => 100.9,
            bid   => 100.9,
            ask   => 100.9
        },
        {
            date  => '2012-06-22 04:00:10',
            quote => 101.2,
            bid   => 101.2,
            ask   => 101.2
        },
        {
            date  => '2012-06-22 09:00:20',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },
        {
            date  => '2012-06-22 15:00:40',
            quote => 100.8,
            bid   => 100.8,
            ask   => 100.8
        },

        {
            date  => '2012-06-24 01:00:00',
            quote => 100.7,
            bid   => 100.7,
            ask   => 100.7
        },
        {
            date  => '2012-06-24 04:00:10',
            quote => 105.2,
            bid   => 105.2,
            ask   => 105.2
        },
        {
            date  => '2012-06-24 09:00:20',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },
        {
            date  => '2012-06-24 15:00:40',
            quote => 100.6,
            bid   => 100.6,
            ask   => 100.6
        },

        {
            date  => '2012-06-30 01:00:00',
            quote => 102.8,
            bid   => 102.8,
            ask   => 102.8
        },
        {
            date  => '2012-06-30 04:00:10',
            quote => 104.2,
            bid   => 104.2,
            ask   => 104.2
        },
        {
            date  => '2012-06-30 09:00:20',
            quote => 100.8,
            bid   => 100.8,
            ask   => 100.8
        },
        {
            date  => '2012-06-30 15:00:40',
            quote => 101.3,
            bid   => 101.3,
            ask   => 101.3
        },

        {
            date  => '2012-07-01 01:00:00',
            quote => 100.6,
            bid   => 100.6,
            ask   => 100.6
        },
        {
            date  => '2012-07-01 04:00:10',
            quote => 105.2,
            bid   => 105.2,
            ask   => 105.2
        },
        {
            date  => '2012-07-01 09:00:20',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },
        {
            date  => '2012-07-01 15:00:40',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },

        {
            date  => '2012-07-03 01:00:00',
            quote => 101.7,
            bid   => 101.7,
            ask   => 101.7
        },
        {
            date  => '2012-07-03 04:00:10',
            quote => 104.2,
            bid   => 104.2,
            ask   => 104.2
        },
        {
            date  => '2012-07-03 09:00:20',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },
        {
            date  => '2012-07-03 15:00:40',
            quote => 103.2,
            bid   => 103.2,
            ask   => 103.2
        },

        {
            date  => '2012-07-05 01:00:00',
            quote => 97.8,
            bid   => 97.8,
            ask   => 97.8
        },
        {
            date  => '2012-07-05 04:00:10',
            quote => 100.2,
            bid   => 100.2,
            ask   => 100.2
        },
        {
            date  => '2012-07-05 09:00:20',
            quote => 96.4,
            bid   => 96.4,
            ask   => 96.4
        },
        {
            date  => '2012-07-05 15:00:40',
            quote => 97.2,
            bid   => 97.2,
            ask   => 97.2
        },

        {
            date  => '2012-07-06 01:00:00',
            quote => 98.2,
            bid   => 98.2,
            ask   => 98.2
        },
        {
            date  => '2012-07-06 04:00:10',
            quote => 100.2,
            bid   => 100.2,
            ask   => 100.2
        },
        {
            date  => '2012-07-06 09:00:20',
            quote => 98.2,
            bid   => 98.2,
            ask   => 98.2
        },
        {
            date  => '2012-07-06 15:00:40',
            quote => 99.7,
            bid   => 99.7,
            ask   => 99.7
        },

        {
            date  => '2012-07-07 15:00:40',
            quote => 99.7,
            bid   => 99.7,
            ask   => 99.7
        },

    );

    foreach my $ohlc (@ohlc_daily) {
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

subtest '1 week OHLC Fetch - Start-End-limit' => sub {
    my $api = Postgres::FeedDB::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);

    my $ohlcs = $api->ohlc_start_end_with_limit_for_charting({
        start_time         => '2012-05-27 00:00:00',
        end_time           => '2012-07-08 00:00:00',
        aggregation_period => 604800,
        limit              => 3,
    });
    isa_ok $ohlcs, 'ARRAY', 'Got ohlc for 2012-05-27 00:00:00 to 2012-07-03 00:00:00 (limit 3)';
    is scalar @$ohlcs, 3, '3 OHLC found';

    subtest 'ohlc datatype' => sub {
        foreach my $ohlc (@$ohlcs) {
            my $date = Date::Utility->new({epoch => $ohlc->epoch});
            isa_ok $ohlc, 'Postgres::FeedDB::Spot::OHLC', $date->datetime_yyyymmdd_hhmmss;
        }
    };

    subtest 'Order Check - Descending' => sub {
        my $previous_ohlc = 99999999999;
        foreach my $ohlc (@$ohlcs) {
            my $date = Date::Utility->new({epoch => $ohlc->epoch});
            ok $ohlc->epoch < $previous_ohlc, 'Checking ' . $date->datetime_yyyymmdd_hhmmss;
            $previous_ohlc = $ohlc->epoch;
        }
    };

    subtest 'No frxUSDAUD' => sub {
        foreach my $ohlc (@$ohlcs) {
            my $date = Date::Utility->new({epoch => $ohlc->epoch});
            ok $ohlc->open > 2, 'Open at ' . $date->datetime_yyyymmdd_hhmmss . ' is frxUSDJPY';
        }
    };

    subtest 'first ohlc match' => sub {
        is($ohlcs->[0]->epoch, Date::Utility->new('2012-07-02 00:00:00')->epoch, 'time match');
        is($ohlcs->[0]->open,  101.7,                                            'open match');
        is($ohlcs->[0]->high,  104.2,                                            'high match');
        is($ohlcs->[0]->low,   96.4,                                             'low match');
        is($ohlcs->[0]->close, 99.7,                                             'close match');
    };

    subtest 'second ohlc match' => sub {
        is($ohlcs->[1]->epoch, Date::Utility->new('2012-06-25 00:00:00')->epoch, 'time match');
        is($ohlcs->[1]->open,  102.8,                                            'open match');
        is($ohlcs->[1]->high,  105.2,                                            'high match');
        is($ohlcs->[1]->low,   100.4,                                            'low match');
        is($ohlcs->[1]->close, 100.4,                                            'close match');
    };

    subtest 'third ohlc match' => sub {
        is($ohlcs->[2]->epoch, Date::Utility->new('2012-06-18 00:00:00')->epoch, 'time match');
        is($ohlcs->[2]->open,  98.4,                                             'open match');
        is($ohlcs->[2]->high,  105.2,                                            'high match');
        is($ohlcs->[2]->low,   97.2,                                             'low match');
        is($ohlcs->[2]->close, 100.6,                                            'close match');
    };
};

my ($ohlcs, $ohlcs_2);
$start_time = '2012-06-04 00:00:00';
$end_time   = '2012-06-18 00:00:00';

subtest '1 week OHLC Fetch - Start-End-limit (Big limit)' => sub {
    my $api = Postgres::FeedDB::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);

    $ohlcs = $api->ohlc_start_end_with_limit_for_charting({
        start_time         => $start_time,
        end_time           => $end_time,
        aggregation_period => 604800,
        limit              => 1000,
    });
    isa_ok $ohlcs, 'ARRAY', "Got ohlcs for $start_time to $end_time and";
    is scalar @$ohlcs, 3, '3 ticks found, we are almost there';

    subtest 'OHLC Quality' => sub {
        foreach my $ohlc (@$ohlcs) {
            my $date1 = Date::Utility->new($end_time);
            my $date2 = Date::Utility->new({epoch => $ohlc->epoch});
            ok $ohlc->epoch <= $date1->epoch, 'OHLC ' . $date2->datetime_yyyymmdd_hhmmss . ' <= ' . $end_time;
        }
    };

    subtest 'first ohlc match' => sub {
        is($ohlcs->[0]->epoch, Date::Utility->new('2012-06-18 00:00:00')->epoch, 'time match');
        is($ohlcs->[0]->open,  98.4,                                             'open match');
        is($ohlcs->[0]->high,  105.2,                                            'high match');
        is($ohlcs->[0]->low,   97.2,                                             'low match');
        is($ohlcs->[0]->close, 100.6,                                            'close match');
    };

    subtest 'second ohlc match' => sub {
        is($ohlcs->[1]->epoch, Date::Utility->new('2012-06-11 00:00:00')->epoch, 'time match');
        is($ohlcs->[1]->open,  100.2,                                            'open match');
        is($ohlcs->[1]->high,  102.2,                                            'high match');
        is($ohlcs->[1]->low,   100.1,                                            'low match');
        is($ohlcs->[1]->close, 100.4,                                            'close match');
    };

    subtest 'third ohlc match' => sub {
        is($ohlcs->[2]->epoch, Date::Utility->new('2012-06-04 00:00:00')->epoch, 'time match');
        is($ohlcs->[2]->open,  100.9,                                            'open match');
        is($ohlcs->[2]->high,  105.5,                                            'high match');
        is($ohlcs->[2]->low,   99.1,                                             'low match');
        is($ohlcs->[2]->close, 99.1,                                             'close match');
    };
};

subtest '1 week OHLC Fetch - Access from Underlying feed_api' => sub {
    my $underlying = BOM::Market::Underlying->new('frxUSDJPY');

    $ohlcs_2 = $underlying->feed_api->ohlc_start_end_with_limit_for_charting({
        start_time         => $start_time,
        end_time           => $end_time,
        aggregation_period => 604800,
        limit              => 1000,
    });
    is_deeply($ohlcs, $ohlcs_2, 'access from Underlying feed_api, ohlc match');
};

done_testing;
