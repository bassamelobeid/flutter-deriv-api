#!/etc/rmg/bin/perl

use strict;
use warnings;
use utf8;
use Test::More 0.22 tests => 6;
use Test::Exception;
use Test::NoWarnings;
use Test::Warn;

use DateTime;
use Date::Parse;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use Quant::Framework::Spot::DatabaseAPI;
use Quant::Framework::Spot::OHLC;
use Date::Utility;

use Quant::Framework::Spot::DatabaseAPI;
my $dbh = BOM::Database::FeedDB::read_dbh;
$dbh->{RaiseError} = 1;

subtest 'prepare ohlc minutely' => sub {
    my @ohlc_minute = (

        {
            date  => '2012-06-01 10:00:00',
            quote => 100.1,
            bid   => 100.1,
            ask   => 100.1
        },
        {
            date  => '2012-06-01 10:00:10',
            quote => 101.4,
            bid   => 101.4,
            ask   => 101.4
        },
        {
            date  => '2012-06-01 10:00:20',
            quote => 100.1,
            bid   => 100.1,
            ask   => 100.1
        },
        {
            date  => '2012-06-01 10:00:40',
            quote => 101.3,
            bid   => 101.3,
            ask   => 101.3
        },

        {
            date  => '2012-06-01 10:01:00',
            quote => 100.9,
            bid   => 100.9,
            ask   => 100.9
        },
        {
            date  => '2012-06-01 10:01:10',
            quote => 100.9,
            bid   => 100.9,
            ask   => 100.9
        },
        {
            date  => '2012-06-01 10:01:20',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },
        {
            date  => '2012-06-01 10:01:40',
            quote => 100.2,
            bid   => 100.2,
            ask   => 100.2
        },

        {
            date  => '2012-06-01 10:02:00',
            quote => 100.5,
            bid   => 100.5,
            ask   => 100.5
        },
        {
            date  => '2012-06-01 10:02:10',
            quote => 101.2,
            bid   => 101.2,
            ask   => 101.2
        },
        {
            date  => '2012-06-01 10:02:20',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },
        {
            date  => '2012-06-01 10:02:40',
            quote => 101.1,
            bid   => 101.1,
            ask   => 101.1
        },

        {
            date  => '2012-06-01 10:03:00',
            quote => 100.3,
            bid   => 100.3,
            ask   => 100.3
        },
        {
            date  => '2012-06-01 10:03:10',
            quote => 105.2,
            bid   => 105.2,
            ask   => 105.2
        },
        {
            date  => '2012-06-01 10:03:20',
            quote => 100.3,
            bid   => 100.3,
            ask   => 100.3
        },
        {
            date  => '2012-06-01 10:03:40',
            quote => 103.1,
            bid   => 103.1,
            ask   => 103.1
        },

        {
            date  => '2012-06-01 10:04:00',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },
        {
            date  => '2012-06-01 10:04:10',
            quote => 105.5,
            bid   => 105.5,
            ask   => 105.5
        },
        {
            date  => '2012-06-01 10:04:20',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },
        {
            date  => '2012-06-01 10:04:40',
            quote => 101.7,
            bid   => 101.7,
            ask   => 101.7
        },

        {
            date  => '2012-06-01 10:05:00',
            quote => 99.9,
            bid   => 99.9,
            ask   => 99.9
        },
        {
            date  => '2012-06-01 10:05:10',
            quote => 100.2,
            bid   => 100.2,
            ask   => 100.2
        },
        {
            date  => '2012-06-01 10:05:20',
            quote => 99.1,
            bid   => 99.1,
            ask   => 99.1
        },
        {
            date  => '2012-06-01 10:05:40',
            quote => 99.1,
            bid   => 99.1,
            ask   => 99.1
        },

        {
            date  => '2012-06-01 10:06:00',
            quote => 100.2,
            bid   => 100.2,
            ask   => 100.2
        },
        {
            date  => '2012-06-01 10:06:10',
            quote => 100.2,
            bid   => 100.2,
            ask   => 100.2
        },
        {
            date  => '2012-06-01 10:06:20',
            quote => 100.1,
            bid   => 100.1,
            ask   => 100.1
        },
        {
            date  => '2012-06-01 10:06:40',
            quote => 100.1,
            bid   => 100.1,
            ask   => 100.1
        },

        {
            date  => '2012-06-01 10:08:00',
            quote => 100.7,
            bid   => 100.7,
            ask   => 100.7
        },
        {
            date  => '2012-06-01 10:08:10',
            quote => 100.9,
            bid   => 100.9,
            ask   => 100.9
        },
        {
            date  => '2012-06-01 10:08:20',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },
        {
            date  => '2012-06-01 10:08:40',
            quote => 100.5,
            bid   => 100.5,
            ask   => 100.5
        },

        {
            date  => '2012-06-01 10:09:00',
            quote => 101.9,
            bid   => 101.9,
            ask   => 101.9
        },
        {
            date  => '2012-06-01 10:09:10',
            quote => 102.2,
            bid   => 102.2,
            ask   => 102.2
        },
        {
            date  => '2012-06-01 10:09:20',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },
        {
            date  => '2012-06-01 10:09:40',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },

        {
            date  => '2012-06-01 10:10:00',
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
            date  => '2012-06-01 10:10:20',
            quote => 97.2,
            bid   => 97.2,
            ask   => 97.2
        },
        {
            date  => '2012-06-01 10:10:40',
            quote => 99.5,
            bid   => 99.5,
            ask   => 99.5
        },

        {
            date  => '2012-06-01 10:12:00',
            quote => 99.2,
            bid   => 99.2,
            ask   => 99.2
        },
        {
            date  => '2012-06-01 10:12:10',
            quote => 100.2,
            bid   => 100.2,
            ask   => 100.2
        },
        {
            date  => '2012-06-01 10:12:20',
            quote => 99.2,
            bid   => 99.2,
            ask   => 99.2
        },
        {
            date  => '2012-06-01 10:12:40',
            quote => 99.8,
            bid   => 99.8,
            ask   => 99.8
        },

        {
            date  => '2012-06-01 10:14:00',
            quote => 100.9,
            bid   => 100.9,
            ask   => 100.9
        },
        {
            date  => '2012-06-01 10:14:10',
            quote => 101.2,
            bid   => 101.2,
            ask   => 101.2
        },
        {
            date  => '2012-06-01 10:14:20',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },
        {
            date  => '2012-06-01 10:14:40',
            quote => 100.8,
            bid   => 100.8,
            ask   => 100.8
        },

        {
            date  => '2012-06-01 10:17:00',
            quote => 100.7,
            bid   => 100.7,
            ask   => 100.7
        },
        {
            date  => '2012-06-01 10:17:10',
            quote => 105.2,
            bid   => 105.2,
            ask   => 105.2
        },
        {
            date  => '2012-06-01 10:17:20',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },
        {
            date  => '2012-06-01 10:17:40',
            quote => 100.6,
            bid   => 100.6,
            ask   => 100.6
        },

        {
            date  => '2012-06-01 10:18:00',
            quote => 102.8,
            bid   => 102.8,
            ask   => 102.8
        },
        {
            date  => '2012-06-01 10:18:10',
            quote => 104.2,
            bid   => 104.2,
            ask   => 104.2
        },
        {
            date  => '2012-06-01 10:18:20',
            quote => 100.8,
            bid   => 100.8,
            ask   => 100.8
        },
        {
            date  => '2012-06-01 10:18:40',
            quote => 101.3,
            bid   => 101.3,
            ask   => 101.3
        },

        {
            date  => '2012-06-01 10:21:00',
            quote => 100.6,
            bid   => 100.6,
            ask   => 100.6
        },
        {
            date  => '2012-06-01 10:21:10',
            quote => 105.2,
            bid   => 105.2,
            ask   => 105.2
        },
        {
            date  => '2012-06-01 10:21:20',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },
        {
            date  => '2012-06-01 10:21:40',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },

        {
            date  => '2012-06-01 10:22:00',
            quote => 101.7,
            bid   => 101.7,
            ask   => 101.7
        },
        {
            date  => '2012-06-01 10:22:10',
            quote => 104.2,
            bid   => 104.2,
            ask   => 104.2
        },
        {
            date  => '2012-06-01 10:22:20',
            quote => 100.4,
            bid   => 100.4,
            ask   => 100.4
        },
        {
            date  => '2012-06-01 10:22:40',
            quote => 103.2,
            bid   => 103.2,
            ask   => 103.2
        },

        {
            date  => '2012-06-01 10:23:00',
            quote => 97.8,
            bid   => 97.8,
            ask   => 97.8
        },
        {
            date  => '2012-06-01 10:23:10',
            quote => 100.2,
            bid   => 100.2,
            ask   => 100.2
        },
        {
            date  => '2012-06-01 10:23:20',
            quote => 96.4,
            bid   => 96.4,
            ask   => 96.4
        },
        {
            date  => '2012-06-01 10:23:40',
            quote => 97.2,
            bid   => 97.2,
            ask   => 97.2
        },

        {
            date  => '2012-06-01 10:24:00',
            quote => 98.2,
            bid   => 98.2,
            ask   => 98.2
        },
        {
            date  => '2012-06-01 10:24:10',
            quote => 100.2,
            bid   => 100.2,
            ask   => 100.2
        },
        {
            date  => '2012-06-01 10:24:20',
            quote => 98.2,
            bid   => 98.2,
            ask   => 98.2
        },
        {
            date  => '2012-06-01 10:24:40',
            quote => 99.7,
            bid   => 99.7,
            ask   => 99.7
        },

        {
            date  => '2012-06-01 10:25:00',
            quote => 95.2,
            bid   => 95.2,
            ask   => 95.2
        },
        {
            date  => '2012-06-01 10:25:10',
            quote => 100.2,
            bid   => 100.2,
            ask   => 100.2
        },
        {
            date  => '2012-06-01 10:25:20',
            quote => 94.4,
            bid   => 94.4,
            ask   => 94.4
        },
        {
            date  => '2012-06-01 10:25:40',
            quote => 95.7,
            bid   => 95.7,
            ask   => 95.7
        },

        {
            date  => '2012-06-01 10:26:40',
            quote => 95.7,
            bid   => 95.7,
            ask   => 95.7
        },
    );

    foreach my $ohlc (@ohlc_minute) {
        lives_ok {
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
                epoch      => Date::Parse::str2time($ohlc->{date}),
                quote      => $ohlc->{quote},
                bid        => $ohlc->{bid},
                ask        => $ohlc->{ask},
                underlying => 'frxUSDJPY'
            });
        }
        'for ohlc minutely - ' . $ohlc->{date};
    }
};

subtest '5min OHLC Fetch - Start-End' => sub {
    my $api = Quant::Framework::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);

    my $end_time = '2012-06-01 10:25:00';
    my $ohlcs    = $api->ohlc_start_end({
        start_time         => '2012-06-01 10:00:00',
        end_time           => $end_time,
        aggregation_period => 300,
    });
    isa_ok $ohlcs, 'ARRAY', "Got ohlc for 2012-06-01 10:00:00 to $end_time and";
    is scalar @$ohlcs, 6, '6 OHLC found';

    subtest 'ohlc datatype' => sub {
        foreach my $ohlc (@$ohlcs) {
            my $date = Date::Utility->new({epoch => $ohlc->epoch});
            isa_ok $ohlc, 'Quant::Framework::Spot::OHLC', $date->datetime_yyyymmdd_hhmmss;
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
        is($ohlcs->[1]->epoch, Date::Utility->new('2012-06-01 10:20:00')->epoch, 'time match');
        is($ohlcs->[1]->open,  100.6,                                            'open match');
        is($ohlcs->[1]->high,  105.2,                                            'high match');
        is($ohlcs->[1]->low,   96.4,                                             'low match');
        is($ohlcs->[1]->close, 99.7,                                             'close match');
    };

    subtest 'third ohlc match' => sub {
        is($ohlcs->[2]->epoch, Date::Utility->new('2012-06-01 10:15:00')->epoch, 'time match');
        is($ohlcs->[2]->open,  100.7,                                            'open match');
        is($ohlcs->[2]->high,  105.2,                                            'high match');
        is($ohlcs->[2]->low,   100.4,                                            'low match');
        is($ohlcs->[2]->close, 101.3,                                            'close match');
    };

    subtest 'forth ohlc match' => sub {
        is($ohlcs->[3]->epoch, Date::Utility->new('2012-06-01 10:10:00')->epoch, 'time match');
        is($ohlcs->[3]->open,  98.4,                                             'open match');
        is($ohlcs->[3]->high,  101.2,                                            'high match');
        is($ohlcs->[3]->low,   97.2,                                             'low match');
        is($ohlcs->[3]->close, 100.8,                                            'close match');
    };

    subtest 'fiveth ohlc match' => sub {
        is($ohlcs->[4]->epoch, Date::Utility->new('2012-06-01 10:05:00')->epoch, 'time match');
        is($ohlcs->[4]->open,  99.9,                                             'open match');
        is($ohlcs->[4]->high,  102.2,                                            'high match');
        is($ohlcs->[4]->low,   99.1,                                             'low match');
        is($ohlcs->[4]->close, 100.4,                                            'close match');
    };

    subtest 'sixth ohlc match' => sub {
        is($ohlcs->[5]->epoch, Date::Utility->new('2012-06-01 10:00:00')->epoch, 'time match');
        is($ohlcs->[5]->open,  100.1,                                            'open match');
        is($ohlcs->[5]->high,  105.5,                                            'high match');
        is($ohlcs->[5]->low,   100.1,                                            'low match');
        is($ohlcs->[5]->close, 101.7,                                            'close match');
    };
};

subtest '5min OHLC Fetch - Start-End - Narrower' => sub {
    my $api = Quant::Framework::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);

    my $start_time = '2012-06-01 10:05:00';
    my $end_time   = '2012-06-01 10:20:00';
    my $ohlcs      = $api->ohlc_start_end({
        start_time         => $start_time,
        end_time           => $end_time,
        aggregation_period => 300,
    });
    isa_ok $ohlcs, 'ARRAY', "Got ohlcs for $start_time to $end_time and";
    is scalar @$ohlcs, 4, '4 ohlcs found, we are almost there';

    subtest 'OHLC Quality' => sub {
        foreach my $ohlc (@$ohlcs) {
            my $date1 = Date::Utility->new($end_time);
            my $date2 = Date::Utility->new({epoch => $ohlc->epoch});
            ok $ohlc->epoch <= $date1->epoch, 'OHLC ' . $date2->datetime_yyyymmdd_hhmmss . ' <= ' . $end_time;
        }
    };

    subtest 'first ohlc match' => sub {
        is($ohlcs->[0]->epoch, Date::Utility->new('2012-06-01 10:20:00')->epoch, 'time match');
        is($ohlcs->[0]->open,  100.6,                                            'open match');
        is($ohlcs->[0]->high,  105.2,                                            'high match');
        is($ohlcs->[0]->low,   96.4,                                             'low match');
        is($ohlcs->[0]->close, 99.7,                                             'close match');
    };
    subtest 'second ohlc match' => sub {
        is($ohlcs->[1]->epoch, Date::Utility->new('2012-06-01 10:15:00')->epoch, 'time match');
        is($ohlcs->[1]->open,  100.7,                                            'open match');
        is($ohlcs->[1]->high,  105.2,                                            'high match');
        is($ohlcs->[1]->low,   100.4,                                            'low match');
        is($ohlcs->[1]->close, 101.3,                                            'close match');
    };
    subtest 'third ohlc match' => sub {
        is($ohlcs->[2]->epoch, Date::Utility->new('2012-06-01 10:10:00')->epoch, 'time match');
        is($ohlcs->[2]->open,  98.4,                                             'open match');
        is($ohlcs->[2]->high,  101.2,                                            'high match');
        is($ohlcs->[2]->low,   97.2,                                             'low match');
        is($ohlcs->[2]->close, 100.8,                                            'close match');
    };
    subtest 'forth ohlc match' => sub {
        is($ohlcs->[3]->epoch, Date::Utility->new('2012-06-01 10:05:00')->epoch, 'time match');
        is($ohlcs->[3]->open,  99.9,                                             'open match');
        is($ohlcs->[3]->high,  102.2,                                            'high match');
        is($ohlcs->[3]->low,   99.1,                                             'low match');
        is($ohlcs->[3]->close, 100.4,                                            'close match');
    };
};

subtest '5min OHLC Fetch - Start-End - Way off mark' => sub {
    my $api = Quant::Framework::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);

    my $ohlcs = $api->ohlc_start_end({
        start_time         => '2012-03-15 00:00:00',
        end_time           => '2012-04-15 23:00:00',
        aggregation_period => 300,
    });
    isa_ok $ohlcs, 'ARRAY', 'Got ohlcs for 2012-03-15 00:00:00 to 2012-04-15 23:00:00 and';
    is scalar @$ohlcs, 0, '0 ohlc found';
};

subtest '5min OHLC Fetch - Start-End - Beserk User' => sub {
    my $api = Quant::Framework::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);

    throws_ok {
        warning_like {
            my $ohlcs = $api->ohlc_start_end({
                end_time           => '2012-05-15 23:00:00',
                aggregation_period => 300
            });
        }
        qr/Error sanity_checks_start_end: start time(<NULL>) and end time(2012-05-15 23:00:00) should be provided/;
    }
    qr/Error sanity_checks_start_end: start time\(<NULL>\) and end time\(2012-05-15 23:00:00\) should be provided/,
        'No Start Time -  We don\'t entertain such queries';

    throws_ok {
        warnings_like {
            my $ohlcs = $api->ohlc_start_end({
                start_time         => '2012-05-22 00:00:00',
                aggregation_period => 300
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
                end_time           => '2012-05-15 23:00:00',
                aggregation_period => 300
            });
        }
        qr/Error sanity_checks_start_end: end time\(2012-05-22 00:00:00\) < start time\(2012-05-15 23:00:00\)/;
    }
    qr/Error sanity_checks_start_end: end time\(1337122800\) < start time\(1337644800\)/, 'end time should be > start time';
};

