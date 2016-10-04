#!/etc/rmg/bin/perl

use strict;
use warnings;
use utf8;
use Test::More 0.22 tests => 6;
use Test::Exception;
use Test::Warn;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

use Postgres::FeedDB::Spot::DatabaseAPI;
use Postgres::FeedDB::Spot::OHLC;
use DateTime;
use Date::Utility;
use Date::Parse;

use Postgres::FeedDB::Spot::DatabaseAPI;
my $dbh = Postgres::FeedDB::read_dbh;
$dbh->{RaiseError} = 1;

subtest 'prepare ohlc hourly' => sub {
    my @ohlc_hour = ({
            date  => '2012-06-01 00:00:00',
            quote => 100.1,
            bid   => 100.1,
            ask   => 100.1
        },
        {
            date  => '2012-06-01 00:10:10',
            quote => 101.4,
            bid   => 101.4,
            ask   => 101.4
        },
        {
            date  => '2012-06-01 00:20:20',
            quote => 100.1,
            bid   => 100.1,
            ask   => 100.1
        },
        {
            date  => '2012-06-01 00:40:40',
            quote => 101.3,
            bid   => 101.3,
            ask   => 101.3
        },

        {
            date  => '2012-06-01 01:00:00',
            quote => 100.9,
            bid   => 100.9,
            ask   => 100.9
        },
        {
            date  => '2012-06-01 01:10:10',
            quote => 100.9,
            bid   => 100.9,
            ask   => 100.9
        },
        {
            date  => '2012-06-01 01:20:20',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },
        {
            date  => '2012-06-01 01:40:40',
            quote => 100.2,
            bid   => 100.2,
            ask   => 100.2
        },

        {
            date  => '2012-06-01 02:00:00',
            quote => 100.5,
            bid   => 100.5,
            ask   => 100.5
        },
        {
            date  => '2012-06-01 02:10:10',
            quote => 101.2,
            bid   => 101.2,
            ask   => 101.2
        },
        {
            date  => '2012-06-01 02:20:20',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },
        {
            date  => '2012-06-01 02:40:40',
            quote => 101.1,
            bid   => 101.1,
            ask   => 101.1
        },

        {
            date  => '2012-06-01 03:00:00',
            quote => 100.3,
            bid   => 100.3,
            ask   => 100.3
        },
        {
            date  => '2012-06-01 03:10:10',
            quote => 105.2,
            bid   => 105.2,
            ask   => 105.2
        },
        {
            date  => '2012-06-01 03:20:20',
            quote => 100.3,
            bid   => 100.3,
            ask   => 100.3
        },
        {
            date  => '2012-06-01 03:40:40',
            quote => 103.1,
            bid   => 103.1,
            ask   => 103.1
        },

        {
            date  => '2012-06-01 04:00:00',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },
        {
            date  => '2012-06-01 04:10:10',
            quote => 105.5,
            bid   => 105.5,
            ask   => 105.5
        },
        {
            date  => '2012-06-01 04:20:20',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },
        {
            date  => '2012-06-01 04:40:40',
            quote => 101.7,
            bid   => 101.7,
            ask   => 101.7
        },

        {
            date  => '2012-06-01 05:00:00',
            quote => 99.9,
            bid   => 99.9,
            ask   => 99.9
        },
        {
            date  => '2012-06-01 05:10:10',
            quote => 100.2,
            bid   => 100.2,
            ask   => 100.2
        },
        {
            date  => '2012-06-01 05:20:20',
            quote => 99.1,
            bid   => 99.1,
            ask   => 99.1
        },
        {
            date  => '2012-06-01 05:40:40',
            quote => 99.1,
            bid   => 99.1,
            ask   => 99.1
        },

        {
            date  => '2012-06-01 06:00:00',
            quote => 100.2,
            bid   => 100.2,
            ask   => 100.2
        },
        {
            date  => '2012-06-01 06:10:10',
            quote => 100.2,
            bid   => 100.2,
            ask   => 100.2
        },
        {
            date  => '2012-06-01 06:20:20',
            quote => 100.1,
            bid   => 100.1,
            ask   => 100.1
        },
        {
            date  => '2012-06-01 06:40:40',
            quote => 100.1,
            bid   => 100.1,
            ask   => 100.1
        },

        {
            date  => '2012-06-01 08:00:00',
            quote => 100.7,
            bid   => 100.7,
            ask   => 100.7
        },
        {
            date  => '2012-06-01 08:10:10',
            quote => 100.9,
            bid   => 100.9,
            ask   => 100.9
        },
        {
            date  => '2012-06-01 08:20:20',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },
        {
            date  => '2012-06-01 08:40:40',
            quote => 100.5,
            bid   => 100.5,
            ask   => 100.5
        },

        {
            date  => '2012-06-01 09:00:00',
            quote => 101.9,
            bid   => 101.9,
            ask   => 101.9
        },
        {
            date  => '2012-06-01 09:10:10',
            quote => 102.2,
            bid   => 102.2,
            ask   => 102.2
        },
        {
            date  => '2012-06-01 09:20:20',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },
        {
            date  => '2012-06-01 09:40:40',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },

        {
            date  => '2012-06-01 10:00:00',
            quote => 98.4,
            bid   => 98.4,
            ask   => 98.4
        },
        {
            date  => '2012-06-01 10:10:10',
            quote => 100.2,
            bid   => 100.2,
            ask   => 100.2
        },
        {
            date  => '2012-06-01 10:20:20',
            quote => 97.2,
            bid   => 97.2,
            ask   => 97.2
        },
        {
            date  => '2012-06-01 10:40:40',
            quote => 99.5,
            bid   => 99.5,
            ask   => 99.5
        },

        {
            date  => '2012-06-01 13:00:00',
            quote => 99.2,
            bid   => 99.2,
            ask   => 99.2
        },
        {
            date  => '2012-06-01 13:10:10',
            quote => 100.2,
            bid   => 100.2,
            ask   => 100.2
        },
        {
            date  => '2012-06-01 13:20:20',
            quote => 99.2,
            bid   => 99.2,
            ask   => 99.2
        },
        {
            date  => '2012-06-01 13:40:40',
            quote => 99.8,
            bid   => 99.8,
            ask   => 99.8
        },

        {
            date  => '2012-06-01 14:00:00',
            quote => 100.9,
            bid   => 100.9,
            ask   => 100.9
        },
        {
            date  => '2012-06-01 14:10:10',
            quote => 101.2,
            bid   => 101.2,
            ask   => 101.2
        },
        {
            date  => '2012-06-01 14:20:20',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },
        {
            date  => '2012-06-01 14:40:40',
            quote => 100.8,
            bid   => 100.8,
            ask   => 100.8
        },

        {
            date  => '2012-06-01 15:00:00',
            quote => 100.7,
            bid   => 100.7,
            ask   => 100.7
        },
        {
            date  => '2012-06-01 15:10:10',
            quote => 105.2,
            bid   => 105.2,
            ask   => 105.2
        },
        {
            date  => '2012-06-01 15:20:20',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },
        {
            date  => '2012-06-01 15:40:40',
            quote => 100.6,
            bid   => 100.6,
            ask   => 100.6
        },

        {
            date  => '2012-06-01 18:00:00',
            quote => 102.8,
            bid   => 102.8,
            ask   => 102.8
        },
        {
            date  => '2012-06-01 18:10:10',
            quote => 104.2,
            bid   => 104.2,
            ask   => 104.2
        },
        {
            date  => '2012-06-01 18:20:20',
            quote => 100.8,
            bid   => 100.8,
            ask   => 100.8
        },
        {
            date  => '2012-06-01 18:40:40',
            quote => 101.3,
            bid   => 101.3,
            ask   => 101.3
        },

        {
            date  => '2012-06-01 20:00:00',
            quote => 100.6,
            bid   => 100.6,
            ask   => 100.6
        },
        {
            date  => '2012-06-01 20:10:10',
            quote => 105.2,
            bid   => 105.2,
            ask   => 105.2
        },
        {
            date  => '2012-06-01 20:20:20',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },
        {
            date  => '2012-06-01 20:40:40',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },

        {
            date  => '2012-06-01 21:00:00',
            quote => 101.7,
            bid   => 101.7,
            ask   => 101.7
        },
        {
            date  => '2012-06-01 21:10:10',
            quote => 104.2,
            bid   => 104.2,
            ask   => 104.2
        },
        {
            date  => '2012-06-01 21:20:20',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },
        {
            date  => '2012-06-01 21:40:40',
            quote => 103.2,
            bid   => 103.2,
            ask   => 103.2
        },

        {
            date  => '2012-06-01 22:00:00',
            quote => 97.8,
            bid   => 97.8,
            ask   => 97.8
        },
        {
            date  => '2012-06-01 22:10:10',
            quote => 100.2,
            bid   => 100.2,
            ask   => 100.2
        },
        {
            date  => '2012-06-01 22:20:20',
            quote => 96.4,
            bid   => 96.4,
            ask   => 96.4
        },
        {
            date  => '2012-06-01 22:40:40',
            quote => 97.2,
            bid   => 97.2,
            ask   => 97.2
        },

        {
            date  => '2012-06-01 23:00:00',
            quote => 98.2,
            bid   => 98.2,
            ask   => 98.2
        },
        {
            date  => '2012-06-01 23:10:10',
            quote => 100.2,
            bid   => 100.2,
            ask   => 100.2
        },
        {
            date  => '2012-06-01 23:20:20',
            quote => 98.2,
            bid   => 98.2,
            ask   => 98.2
        },
        {
            date  => '2012-06-01 23:40:40',
            quote => 99.7,
            bid   => 99.7,
            ask   => 99.7
        },

        {
            date  => '2012-06-02 00:00:00',
            quote => 95.2,
            bid   => 95.2,
            ask   => 95.2
        },
        {
            date  => '2012-06-02 00:10:10',
            quote => 100.2,
            bid   => 100.2,
            ask   => 100.2
        },
        {
            date  => '2012-06-02 00:20:20',
            quote => 94.4,
            bid   => 94.4,
            ask   => 94.4
        },
        {
            date  => '2012-06-02 00:40:40',
            quote => 95.7,
            bid   => 95.7,
            ask   => 95.7
        },

        {
            date  => '2012-06-02 03:00:00',
            quote => 100.5,
            bid   => 100.5,
            ask   => 100.5
        },
        {
            date  => '2012-06-02 03:10:10',
            quote => 100.9,
            bid   => 100.9,
            ask   => 100.9
        },
        {
            date  => '2012-06-02 03:20:20',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },
        {
            date  => '2012-06-02 03:40:40',
            quote => 100.7,
            bid   => 100.7,
            ask   => 100.7
        },

        {
            date  => '2012-06-02 05:00:00',
            quote => 95.2,
            bid   => 95.2,
            ask   => 95.2
        },
        {
            date  => '2012-06-02 05:10:10',
            quote => 100.2,
            bid   => 100.2,
            ask   => 100.2
        },
        {
            date  => '2012-06-02 05:20:20',
            quote => 94.4,
            bid   => 94.4,
            ask   => 94.4
        },
        {
            date  => '2012-06-02 05:40:40',
            quote => 95.7,
            bid   => 95.7,
            ask   => 95.7
        },

        {
            date  => '2012-06-02 06:40:40',
            quote => 95.7,
            bid   => 95.7,
            ask   => 95.7
        },

    );

    foreach my $ohlc (@ohlc_hour) {
        lives_ok {
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
                epoch      => Date::Parse::str2time($ohlc->{date}),
                quote      => $ohlc->{quote},
                bid        => $ohlc->{bid},
                ask        => $ohlc->{ask},
                underlying => 'frxUSDJPY'
            });
        }
        'for ohlc hourly - ' . $ohlc->{date};
    }

};

subtest '4 hr OHLC Fetch - Start-End' => sub {
    my $api = Postgres::FeedDB::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);

    my $end_time = '2012-06-02 04:00:00';
    my $ohlcs    = $api->ohlc_start_end({
        start_time         => '2012-06-01 00:00:00',
        end_time           => $end_time,
        aggregation_period => 14400,
    });
    isa_ok $ohlcs, 'ARRAY', "Got 4 hour ohlc for 2012-06-01 00:00:00 to $end_time and";
    is scalar @$ohlcs, 8, '8 OHLC found';

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
        is($ohlcs->[0]->epoch, Date::Utility->new($end_time)->epoch, 'time match');
        is($ohlcs->[0]->open,  95.2,                                 'open match');
        is($ohlcs->[0]->high,  100.2,                                'high match');
        is($ohlcs->[0]->low,   94.4,                                 'low match');
        is($ohlcs->[0]->close, 95.7,                                 'close match');
    };

    subtest 'second ohlc match' => sub {
        is($ohlcs->[1]->epoch, Date::Utility->new('2012-06-02 00:00:00')->epoch, 'time match');
        is($ohlcs->[1]->open,  95.2,                                             'open match');
        is($ohlcs->[1]->high,  100.9,                                            'high match');
        is($ohlcs->[1]->low,   94.4,                                             'low match');
        is($ohlcs->[1]->close, 100.7,                                            'close match');
    };

    subtest 'third ohlc match' => sub {
        is($ohlcs->[2]->epoch, Date::Utility->new('2012-06-01 20:00:00')->epoch, 'time match');
        is($ohlcs->[2]->open,  100.6,                                            'open match');
        is($ohlcs->[2]->high,  105.2,                                            'high match');
        is($ohlcs->[2]->low,   96.4,                                             'low match');
        is($ohlcs->[2]->close, 99.7,                                             'close match');
    };

    subtest 'forth ohlc match' => sub {
        is($ohlcs->[3]->epoch, Date::Utility->new('2012-06-01 16:00:00')->epoch, 'time match');
        is($ohlcs->[3]->open,  102.8,                                            'open match');
        is($ohlcs->[3]->high,  104.2,                                            'high match');
        is($ohlcs->[3]->low,   100.8,                                            'low match');
        is($ohlcs->[3]->close, 101.3,                                            'close match');
    };

    subtest 'fiveth ohlc match' => sub {
        is($ohlcs->[4]->epoch, Date::Utility->new('2012-06-01 12:00:00')->epoch, 'time match');
        is($ohlcs->[4]->open,  99.2,                                             'open match');
        is($ohlcs->[4]->high,  105.2,                                            'high match');
        is($ohlcs->[4]->low,   99.2,                                             'low match');
        is($ohlcs->[4]->close, 100.6,                                            'close match');
    };

    subtest 'sixth ohlc match' => sub {
        is($ohlcs->[5]->epoch, Date::Utility->new('2012-06-01 08:00:00')->epoch, 'time match');
        is($ohlcs->[5]->open,  100.7,                                            'open match');
        is($ohlcs->[5]->high,  102.2,                                            'high match');
        is($ohlcs->[5]->low,   97.2,                                             'low match');
        is($ohlcs->[5]->close, 99.5,                                             'close match');
    };

    subtest 'seventh ohlc match' => sub {
        is($ohlcs->[6]->epoch, Date::Utility->new('2012-06-01 04:00:00')->epoch, 'time match');
        is($ohlcs->[6]->open,  100.4,                                            'open match');
        is($ohlcs->[6]->high,  105.5,                                            'high match');
        is($ohlcs->[6]->low,   99.1,                                             'low match');
        is($ohlcs->[6]->close, 100.1,                                            'close match');
    };

    subtest 'seventh ohlc match' => sub {
        is($ohlcs->[7]->epoch, Date::Utility->new('2012-06-01 00:00:00')->epoch, 'time match');
        is($ohlcs->[7]->open,  100.1,                                            'open match');
        is($ohlcs->[7]->high,  105.2,                                            'high match');
        is($ohlcs->[7]->low,   100.1,                                            'low match');
        is($ohlcs->[7]->close, 103.1,                                            'close match');
    };
};

subtest '4 hr OHLC Fetch - Start-End - Narrower' => sub {
    my $api = Postgres::FeedDB::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);

    my $start_time = '2012-06-01 00:00:00';
    my $end_time   = '2012-06-01 16:00:00';
    my $ohlcs      = $api->ohlc_start_end({
        start_time         => $start_time,
        end_time           => $end_time,
        aggregation_period => 14400,
    });
    isa_ok $ohlcs, 'ARRAY', "Got ohlcs for $start_time to $end_time and";
    is scalar @$ohlcs, 5, '5 ticks found, we are almost there';

    subtest 'OHLC Quality' => sub {
        foreach my $ohlc (@$ohlcs) {
            my $date1 = Date::Utility->new($end_time);
            my $date2 = Date::Utility->new({epoch => $ohlc->epoch});
            ok $ohlc->epoch <= $date1->epoch, 'OHLC ' . $date2->datetime_yyyymmdd_hhmmss . ' <= ' . $end_time;
        }
    };

#2012-06-02 00:00:00, 95.2, 100.9, 94.4, 95.7
#2012-06-01 16:00:00, 102.8, 105.2, 96.4, 99.7
#2012-06-01 08:00:00, 100.7, 105.2, 97.2, 100.6
#2012-06-01 00:00:00, 100.1, 105.5, 99.1, 100.1

    subtest 'first ohlc match' => sub {
        is($ohlcs->[0]->epoch, Date::Utility->new($end_time)->epoch, 'time match');
        is($ohlcs->[0]->open,  102.8,                                'open match');
        is($ohlcs->[0]->high,  104.2,                                'high match');
        is($ohlcs->[0]->low,   100.8,                                'low match');
        is($ohlcs->[0]->close, 101.3,                                'close match');
    };
    subtest 'second ohlc match' => sub {
        is($ohlcs->[1]->epoch, Date::Utility->new('2012-06-01 12:00:00')->epoch, 'time match');
        is($ohlcs->[1]->open,  99.2,                                             'open match');
        is($ohlcs->[1]->high,  105.2,                                            'high match');
        is($ohlcs->[1]->low,   99.2,                                             'low match');
        is($ohlcs->[1]->close, 100.6,                                            'close match');
    };
    subtest 'third ohlc match' => sub {
        is($ohlcs->[2]->epoch, Date::Utility->new('2012-06-01 08:00:00')->epoch, 'time match');
        is($ohlcs->[2]->open,  100.7,                                            'open match');
        is($ohlcs->[2]->high,  102.2,                                            'high match');
        is($ohlcs->[2]->low,   97.2,                                             'low match');
        is($ohlcs->[2]->close, 99.5,                                             'close match');
    };
    subtest 'forth ohlc match' => sub {
        is($ohlcs->[3]->epoch, Date::Utility->new('2012-06-01 04:00:00')->epoch, 'time match');
        is($ohlcs->[3]->open,  100.4,                                            'open match');
        is($ohlcs->[3]->high,  105.5,                                            'high match');
        is($ohlcs->[3]->low,   99.1,                                             'low match');
        is($ohlcs->[3]->close, 100.1,                                            'close match');
    };
    subtest 'fifth ohlc match' => sub {
        is($ohlcs->[4]->epoch, Date::Utility->new('2012-06-01 00:00:00')->epoch, 'time match');
        is($ohlcs->[4]->open,  100.1,                                            'open match');
        is($ohlcs->[4]->high,  105.2,                                            'high match');
        is($ohlcs->[4]->low,   100.1,                                            'low match');
        is($ohlcs->[4]->close, 103.1,                                            'close match');
    };
};

subtest '8 hr OHLC Fetch - Start-End - Narrower' => sub {
    my $api = Postgres::FeedDB::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);

    my $start_time = '2012-06-01 00:00:00';
    my $end_time   = '2012-06-02 00:00:00';
    my $ohlcs      = $api->ohlc_start_end({
        start_time         => $start_time,
        end_time           => $end_time,
        aggregation_period => 28800,
    });
    isa_ok $ohlcs, 'ARRAY', "Got ohlcs for $start_time to $end_time and";
    is scalar @$ohlcs, 4, '4 ticks found, we are almost there';

    subtest 'OHLC Quality' => sub {
        foreach my $ohlc (@$ohlcs) {
            my $date1 = Date::Utility->new($end_time);
            my $date2 = Date::Utility->new({epoch => $ohlc->epoch});
            ok $ohlc->epoch <= $date1->epoch, 'OHLC ' . $date2->datetime_yyyymmdd_hhmmss . ' <= ' . $end_time;
        }
    };

#2012-06-02 00:00:00, 95.2, 100.9, 94.4, 95.7
#2012-06-01 16:00:00, 102.8, 105.2, 96.4, 99.7
#2012-06-01 08:00:00, 100.7, 105.2, 97.2, 100.6
#2012-06-01 00:00:00, 100.1, 105.5, 99.1, 100.1

    subtest 'first ohlc match' => sub {
        is($ohlcs->[0]->epoch, Date::Utility->new($end_time)->epoch, 'time match');
        is($ohlcs->[0]->open,  95.2,                                 'open match');
        is($ohlcs->[0]->high,  100.9,                                'high match');
        is($ohlcs->[0]->low,   94.4,                                 'low match');
        is($ohlcs->[0]->close, 95.7,                                 'close match');
    };
    subtest 'second ohlc match' => sub {
        is($ohlcs->[1]->epoch, Date::Utility->new('2012-06-01 16:00:00')->epoch, 'time match');
        is($ohlcs->[1]->open,  102.8,                                            'open match');
        is($ohlcs->[1]->high,  105.2,                                            'high match');
        is($ohlcs->[1]->low,   96.4,                                             'low match');
        is($ohlcs->[1]->close, 99.7,                                             'close match');
    };
    subtest 'third ohlc match' => sub {
        is($ohlcs->[2]->epoch, Date::Utility->new('2012-06-01 08:00:00')->epoch, 'time match');
        is($ohlcs->[2]->open,  100.7,                                            'open match');
        is($ohlcs->[2]->high,  105.2,                                            'high match');
        is($ohlcs->[2]->low,   97.2,                                             'low match');
        is($ohlcs->[2]->close, 100.6,                                            'close match');
    };
    subtest 'forth ohlc match' => sub {
        is($ohlcs->[3]->epoch, Date::Utility->new('2012-06-01 00:00:00')->epoch, 'time match');
        is($ohlcs->[3]->open,  100.1,                                            'open match');
        is($ohlcs->[3]->high,  105.5,                                            'high match');
        is($ohlcs->[3]->low,   99.1,                                             'low match');
        is($ohlcs->[3]->close, 100.1,                                            'close match');
    };
};

subtest '4 hr OHLC Fetch - Start-End - Way off mark' => sub {
    my $api = Postgres::FeedDB::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);

    my $ohlcs = $api->ohlc_start_end({
        start_time         => '2012-03-15 00:00:00',
        end_time           => '2012-04-15 16:00:00',
        aggregation_period => 18000,
    });
    isa_ok $ohlcs, 'ARRAY', 'Got ohlcs for 2012-03-15 00:00:00 to 2012-04-15 16:00:00 and';
    is scalar @$ohlcs, 0, '0 ohlc found';
};

subtest '4 hr OHLC Fetch - Start-End - Beserk User' => sub {
    my $api = Postgres::FeedDB::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);

    throws_ok {
        warning_like {
            my $ohlcs = $api->ohlc_start_end({
                end_time           => '2012-05-15 16:00:00',
                aggregation_period => 14400,
            });
        }
        qr/Error sanity_checks_start_end: start time(<NULL>) and end time(2012-05-15 16:00:00) should be provided/;
    }
    qr/Error sanity_checks_start_end: start time\(<NULL>\) and end time\(2012-05-15 16:00:00\) should be provided/,
        'No Start Time -  We don\'t entertain such queries';

    throws_ok {
        warnings_like {
            my $ohlcs = $api->ohlc_start_end({
                start_time         => '2012-05-22 00:00:00',
                aggregation_period => 144000,
            });
        }
        qr/Error sanity_checks_start_end: start time\(2012-05-22 00:00:00\) and end time\(<NULL>\) should be provided/;
    }
    qr/Error sanity_checks_start_end: start time\(2012-05-22 00:00:00\) and end time\(<NULL>\) should be provided/,
        'No End Time -  We don\'t entertain such queries';

    throws_ok {
        warnings_like {
            my $ohlcs = $api->ohlc_start_end({
                start_time         => '2012-05-22 00:00:00',
                end_time           => '2012-05-15 16:00:00',
                aggregation_period => 14400,
            });
        }
        qr/Error sanity_checks_start_end: end time\(2012-05-22 00:00:00\) < start time\(2012-05-15 16:00:00\)/;
    }
    qr/Error sanity_checks_start_end: end time\(1337097600\) < start time\(1337644800\)/, 'end time should be > start time';
};

