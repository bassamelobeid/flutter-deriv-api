#!/etc/rmg/bin/perl

use strict;
use warnings;
use utf8;
use Test::More 0.22 tests => 5;
use Test::Exception;
use Test::Warn;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Database::FeedDB;

use Quant::Framework::Spot::OHLC;
use DateTime;
use Date::Utility;

use Quant::Framework::Spot::DatabaseAPI;
my $dbh = BOM::Database::FeedDB::read_dbh;
$dbh->{RaiseError} = 1;

subtest 'prepare ticks' => sub {
    my @ticks = ({
            date  => '2012-07-01 10:00:01',
            quote => 100.1,
            bid   => 100.2,
            ask   => 100.4
        },
        {
            date  => '2012-07-01 10:00:10',
            quote => 100.5,
            bid   => 100.2,
            ask   => 100.4
        },
        {
            date  => '2012-07-01 10:00:15',
            quote => 100.3,
            bid   => 100.2,
            ask   => 100.4
        },
        {
            date  => '2012-07-01 10:00:20',
            quote => 100.4,
            bid   => 100.2,
            ask   => 100.4
        },
        {
            date  => '2012-07-01 10:00:29',
            quote => 99.9,
            bid   => 100.2,
            ask   => 100.4
        },

        {
            date  => '2012-07-01 10:00:30',
            quote => 100.2,
            bid   => 100.2,
            ask   => 100.4
        },
        {
            date  => '2012-07-01 10:00:40',
            quote => 100.7,
            bid   => 100.2,
            ask   => 100.4
        },
        {
            date  => '2012-07-01 10:00:45',
            quote => 101.9,
            bid   => 100.2,
            ask   => 100.4
        },
        {
            date  => '2012-07-01 10:00:50',
            quote => 98.4,
            bid   => 100.2,
            ask   => 100.4
        },
        {
            date  => '2012-07-01 10:00:59',
            quote => 99.2,
            bid   => 100.2,
            ask   => 100.4
        },

        {
            date  => '2012-07-01 10:01:00',
            quote => 100.99,
            bid   => 100.2,
            ask   => 100.4
        },
        {
            date  => '2012-07-01 10:01:20',
            quote => 100.77,
            bid   => 100.2,
            ask   => 100.4
        },
        {
            date  => '2012-07-01 10:01:27',
            quote => 102.88,
            bid   => 100.2,
            ask   => 100.4
        },

        {
            date  => '2012-07-01 10:01:30',
            quote => 100.6,
            bid   => 100.2,
            ask   => 100.4
        },
        {
            date  => '2012-07-01 10:01:40',
            quote => 101.7,
            bid   => 100.2,
            ask   => 100.4
        },
        {
            date  => '2012-07-01 10:01:57',
            quote => 97.8,
            bid   => 100.2,
            ask   => 100.4
        },
        {
            date  => '2012-07-01 10:01:59',
            quote => 99.2,
            bid   => 100.2,
            ask   => 100.4
        },
    );

    foreach my $tick (@ticks) {
        my $date_time = $tick->{date};
        $date_time =~ /(\d{4})-(\d\d)-(\d\d)\s(\d\d):(\d\d):(\d\d)/;
        my ($year, $month, $day, $hour, $minute, $second) = ($1, $2, $3, $4, $5, $6);

        lives_ok {
            my $date = DateTime->new(
                year   => $year,
                month  => $month,
                day    => $day,
                hour   => $hour,
                minute => $minute,
                second => $second
            );
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
                    epoch => $date->epoch,
                    quote => $tick->{quote},
                    bid   => $tick->{bid},
                    ask   => $tick->{ask}});
        }
        'Tick - ' . $date_time;
    }
};

subtest '30s OHLC Fetch - Start-End' => sub {
    my $api = Quant::Framework::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh );

    my $ohlcs = $api->ohlc_start_end({
        start_time         => '2012-07-01 10:00:00',
        end_time           => '2012-07-01 10:01:30',
        aggregation_period => 30
    });
    isa_ok $ohlcs, 'ARRAY', 'Got ohlc for 2012-07-01 10:00:00 to 2012-07-01 10:01:30 and';
    is scalar @$ohlcs, 4, '4 OHLC found';

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
        is($ohlcs->[0]->epoch, Date::Utility->new('2012-07-01 10:01:30')->epoch, 'time match');
        is($ohlcs->[0]->open,  100.6,                                            'open match');
        is($ohlcs->[0]->high,  101.7,                                            'high match');
        is($ohlcs->[0]->low,   97.8,                                             'low match');
        is($ohlcs->[0]->close, 99.2,                                             'close match');
    };

    subtest 'second ohlc match' => sub {
        is($ohlcs->[1]->epoch, Date::Utility->new('2012-07-01 10:01:00')->epoch, 'time match');
        is($ohlcs->[1]->open,  100.99,                                           'open match');
        is($ohlcs->[1]->high,  102.88,                                           'high match');
        is($ohlcs->[1]->low,   100.77,                                           'low match');
        is($ohlcs->[1]->close, 102.88,                                           'close match');
    };

    subtest 'third ohlc match' => sub {
        is($ohlcs->[2]->epoch, Date::Utility->new('2012-07-01 10:00:30')->epoch, 'time match');
        is($ohlcs->[2]->open,  100.2,                                            'open match');
        is($ohlcs->[2]->high,  101.9,                                            'high match');
        is($ohlcs->[2]->low,   98.4,                                             'low match');
        is($ohlcs->[2]->close, 99.2,                                             'close match');
    };

    subtest 'forth ohlc match' => sub {
        is($ohlcs->[3]->epoch, Date::Utility->new('2012-07-01 10:00:00')->epoch, 'time match');
        is($ohlcs->[3]->open,  100.1,                                            'open match');
        is($ohlcs->[3]->high,  100.5,                                            'high match');
        is($ohlcs->[3]->low,   99.9,                                             'low match');
        is($ohlcs->[3]->close, 99.9,                                             'close match');
    };
};

subtest '30s OHLC Fetch - Start-End - Narrower' => sub {
    my $api = Quant::Framework::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh );

    my $start_time = '2012-07-01 10:00:00';
    my $end_time   = '2012-07-01 10:01:00';
    my $ohlcs      = $api->ohlc_start_end({
        start_time         => $start_time,
        end_time           => $end_time,
        aggregation_period => 30
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
        is($ohlcs->[0]->epoch, Date::Utility->new('2012-07-01 10:01:00')->epoch, 'time match');
        is($ohlcs->[0]->open,  100.99,                                           'open match');
        is($ohlcs->[0]->high,  102.88,                                           'high match');
        is($ohlcs->[0]->low,   100.77,                                           'low match');
        is($ohlcs->[0]->close, 102.88,                                           'close match');
    };
    subtest 'second ohlc match' => sub {
        is($ohlcs->[1]->epoch, Date::Utility->new('2012-07-01 10:00:30')->epoch, 'time match');
        is($ohlcs->[1]->open,  100.2,                                            'open match');
        is($ohlcs->[1]->high,  101.9,                                            'high match');
        is($ohlcs->[1]->low,   98.4,                                             'low match');
        is($ohlcs->[1]->close, 99.2,                                             'close match');
    };
    subtest 'third ohlc match' => sub {
        is($ohlcs->[2]->epoch, Date::Utility->new('2012-07-01 10:00:00')->epoch, 'time match');
        is($ohlcs->[2]->open,  100.1,                                            'open match');
        is($ohlcs->[2]->high,  100.5,                                            'high match');
        is($ohlcs->[2]->low,   99.9,                                             'low match');
        is($ohlcs->[2]->close, 99.9,                                             'close match');
    };
};

subtest '30s OHLC Fetch - Start-End - Way off mark' => sub {
    my $api = Quant::Framework::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh );

    my $ohlcs = $api->ohlc_start_end({
        start_time         => '2012-03-15 00:00:00',
        end_time           => '2012-04-15 23:00:00',
        aggregation_period => 30
    });
    isa_ok $ohlcs, 'ARRAY', 'Got ohlcs for 2012-03-15 00:00:00 to 2012-04-15 23:00:00 and';
    is scalar @$ohlcs, 0, '0 ticks found';
};

subtest '30s OHLC Fetch - Start-End - Beserk User' => sub {
    my $api = Quant::Framework::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh );

    throws_ok {
        warning_like {
            my $ohlcs = $api->ohlc_start_end({
                end_time           => '2012-05-15 23:00:00',
                aggregation_period => 30
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
                aggregation_period => 30
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
                aggregation_period => 30
            });
        }
        qr/Error sanity_checks_start_end: end time\(2012-05-22 00:00:00\) < start time\(2012-05-15 23:00:00\)/;
    }
    qr/Error sanity_checks_start_end: end time\(1337122800\) < start time\(1337644800\)/, 'end time should be > start time';
};

