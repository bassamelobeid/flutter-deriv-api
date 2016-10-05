#!/etc/rmg/bin/perl

use strict;
use warnings;
use utf8;
use Test::More 0.22 tests => 7;
use Test::Exception;
use Test::Warn;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

use Postgres::FeedDB::Spot::DatabaseAPI;
use Postgres::FeedDB::Spot::OHLC;
use DateTime;
use Date::Utility;

my $dbh = Postgres::FeedDB::read_dbh;
$dbh->{RaiseError} = 1;

subtest 'Test ohlc daily from tick table' => sub {
    my @ticks = ({
            date => '2012-07-07 23:59:59',
            bid  => 98.1,
            ask  => 104.2,
            spot => 100.1
        },

        {
            date => '2012-07-08 00:00:01',
            bid  => 98.1,
            ask  => 104.2,
            spot => 100.2
        },
        {
            date => '2012-07-08 01:30:00',
            bid  => 98.2,
            ask  => 107.2,
            spot => 103.2
        },
        {
            date => '2012-07-08 03:40:50',
            bid  => 98.4,
            ask  => 108.2,
            spot => 99.7
        },
        {
            date => '2012-07-08 07:30:30',
            bid  => 98.5,
            ask  => 109.2,
            spot => 97.7
        },
        {
            date => '2012-07-08 08:09:00',
            bid  => 98.7,
            ask  => 102.2,
            spot => 99.7
        },
        {
            date => '2012-07-08 09:40:05',
            bid  => 98.0,
            ask  => 105.2,
            spot => 102.7
        },
        {
            date => '2012-07-08 10:25:10',
            bid  => 98.9,
            ask  => 103.2,
            spot => 100.7
        },

        {
            date => '2012-07-09 00:00:00',
            bid  => 98.9,
            ask  => 103.2,
            spot => 100.8
        },
        {
            date => '2012-07-09 23:59:59',
            bid  => 98.9,
            ask  => 103.2,
            spot => 100.9
        },

        {
            date => '2012-07-10 00:00:00',
            bid  => 98.9,
            ask  => 103.2,
            spot => 101.0
        },

        {
            date => '2012-07-11 00:00:00',
            bid  => 98.9,
            ask  => 103.2,
            spot => 101.1
        },
        {
            date => '2012-07-11 10:25:10',
            bid  => 98.9,
            ask  => 103.2,
            spot => 101.2
        },

        {
            date => '2012-07-12 10:25:10',
            bid  => 98.9,
            ask  => 103.2,
            spot => 101.3
        },

        {
            date => '2012-07-13 23:59:59',
            bid  => 98.9,
            ask  => 103.2,
            spot => 101.4
        },

        {
            date => '2012-07-14 00:00:00',
            bid  => 98.9,
            ask  => 103.2,
            spot => 101.5
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
                bid   => $tick->{bid},
                ask   => $tick->{ask},
                quote => $tick->{spot},
            });
        }
        'tick - ' . $date_time;
    }
};

my $start_time = '2012-07-08 00:00:00';
my $end_time   = '2012-07-08 11:00:00';
my $api        = Postgres::FeedDB::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);
my ($ohlcs, $ohlc);

subtest 'ohlc_daily_list - within 1 day' => sub {
    lives_ok {
        $ohlcs = $api->ohlc_daily_list({
            start_time => $start_time,
            end_time   => $end_time,
            official   => 0,
        });
    }
    "get ohlc daily from tick table for $start_time. same day";

    my $ohlc = $ohlcs->[0];
    subtest 'ohlc daily from tick table' => sub {
        is($ohlc->epoch, Date::Utility->new($start_time)->epoch, 'time match');
        is($ohlc->open,  100.2,                                  'open match');
        is($ohlc->high,  103.2,                                  'high match');
        is($ohlc->low,   97.7,                                   'low match');
        is($ohlc->close, 100.7,                                  'close match');
    };
};

subtest 'ohlc_daily_list - 1 day+' => sub {
    lives_ok {
        $ohlcs = $api->ohlc_daily_list({
            start_time => '2012-07-08 00:00:00',
            end_time   => '2012-07-09 00:00:00',
            official   => 0,
        });
    }
    "get ohlc daily from tick table for $start_time. same day + start second of next day";

    $ohlc = $ohlcs->[0];
    subtest 'ohlc daily from tick table day one' => sub {
        is($ohlc->epoch, Date::Utility->new($start_time)->epoch, 'time match');
        is($ohlc->open,  100.2,                                  'open match');
        is($ohlc->high,  103.2,                                  'high match');
        is($ohlc->low,   97.7,                                   'low match');
        is($ohlc->close, 100.7,                                  'close match');
    };

    $ohlc = $ohlcs->[1];
    subtest 'ohlc daily from tick table from two different days' => sub {
        is($ohlc->epoch, Date::Utility->new('2012-07-09')->epoch, 'time match');
        is($ohlc->open,  100.8,                                   'open match');
        is($ohlc->high,  100.8,                                   'high match');
        is($ohlc->low,   100.8,                                   'low match');
        is($ohlc->close, 100.8,                                   'close match');
    };
};

subtest 'ohlc_daily_list - 1 day+' => sub {
    lives_ok {
        $ohlcs = $api->ohlc_daily_list({
            start_time => '2012-07-08 00:00:00',
            end_time   => '2012-07-09 00:00:01',
            official   => 0,
        });
    }
    "get ohlc daily from tick table for 2012-7-8 00:00:00 - 2012-7-9 00:00:01";

    $ohlc = $ohlcs->[0];
    subtest 'ohlc daily from tick table' => sub {
        is($ohlc->epoch, Date::Utility->new('2012-07-08')->epoch, 'time match');
        is($ohlc->open,  100.2,                                   'open match');
        is($ohlc->high,  103.2,                                   'high match');
        is($ohlc->low,   97.7,                                    'low match');
        is($ohlc->close, 100.7,                                   'close match');
    };

    $ohlc = $ohlcs->[1];
    subtest 'ohlc daily from tick table from two different days' => sub {
        is($ohlc->epoch, Date::Utility->new('2012-07-09')->epoch, 'time match');
        is($ohlc->open,  100.8,                                   'open match');
        is($ohlc->high,  100.8,                                   'high match');
        is($ohlc->low,   100.8,                                   'low match');
        is($ohlc->close, 100.8,                                   'close match');
    };
};

subtest 'ohlc_daily_list - across 3 days' => sub {
    lives_ok {
        $ohlcs = $api->ohlc_daily_list({
            start_time => '2012-07-07 23:59:59',
            end_time   => '2012-07-09 00:00:01',
            official   => 0,
        });
    }
    "get ohlc daily from tick table for 2012-7-7 23:59:59 - 2012-7-9 00:00:01";

    $ohlc = $ohlcs->[0];
    subtest 'ohlc daily from tick table' => sub {
        is($ohlc->epoch, Date::Utility->new('2012-07-07')->epoch, 'time match');
        is($ohlc->open,  100.1,                                   'open match');
        is($ohlc->high,  100.1,                                   'high match');
        is($ohlc->low,   100.1,                                   'low match');
        is($ohlc->close, 100.1,                                   'close match');
    };

    $ohlc = $ohlcs->[1];
    subtest 'ohlc daily from tick table' => sub {
        is($ohlc->epoch, Date::Utility->new('2012-07-08')->epoch, 'time match');
        is($ohlc->open,  100.2,                                   'open match');
        is($ohlc->high,  103.2,                                   'high match');
        is($ohlc->low,   97.7,                                    'low match');
        is($ohlc->close, 100.7,                                   'close match');
    };

    $ohlc = $ohlcs->[2];
    subtest 'ohlc daily from tick table from two different days' => sub {
        is($ohlc->epoch, Date::Utility->new('2012-07-09')->epoch, 'time match');
        is($ohlc->open,  100.8,                                   'open match');
        is($ohlc->high,  100.8,                                   'high match');
        is($ohlc->low,   100.8,                                   'low match');
        is($ohlc->close, 100.8,                                   'close match');
    };
};

subtest 'ohlc_daily_list - across 3 days' => sub {
    lives_ok {
        $ohlcs = $api->ohlc_daily_list({
            start_time => '2012-07-07 23:59:59',
            end_time   => '2012-07-09 23:59:59',
            official   => 0,
        });
    }
    "get ohlc daily from tick table for 2012-7-7 23:59:59 - 2012-7-9 23:59:59";

    $ohlc = $ohlcs->[0];
    subtest 'ohlc daily from tick table' => sub {
        is($ohlc->epoch, Date::Utility->new('2012-07-07')->epoch, 'time match');
        is($ohlc->open,  100.1,                                   'open match');
        is($ohlc->high,  100.1,                                   'high match');
        is($ohlc->low,   100.1,                                   'low match');
        is($ohlc->close, 100.1,                                   'close match');
    };
    $ohlc = $ohlcs->[1];

    subtest 'ohlc daily from tick table' => sub {
        is($ohlc->epoch, Date::Utility->new('2012-07-08')->epoch, 'time match');
        is($ohlc->open,  100.2,                                   'open match');
        is($ohlc->high,  103.2,                                   'high match');
        is($ohlc->low,   97.7,                                    'low match');
        is($ohlc->close, 100.7,                                   'close match');
    };
    $ohlc = $ohlcs->[2];

    subtest 'ohlc daily from tick table from two different days' => sub {
        is($ohlc->epoch, Date::Utility->new('2012-07-09')->epoch, 'time match');
        is($ohlc->open,  100.8,                                   'open match');
        is($ohlc->high,  100.9,                                   'high match');
        is($ohlc->low,   100.8,                                   'low match');
        is($ohlc->close, 100.9,                                   'close match');
    };
};

subtest 'ohlc_daily_list - across 8 days' => sub {
    lives_ok {
        $ohlcs = $api->ohlc_daily_list({
            start_time => '2012-07-07 23:59:59',
            end_time   => '2012-07-14 00:00:00',
            official   => 0,
        });
    }
    "get ohlc daily from tick table for 2012-7-7 23:59:59 - 2012-7-9 23:59:59";
    is(scalar(@{$ohlcs}), 8, 'Number of days correct');

    subtest 'first ohlc - from tick table' => sub {
        is($ohlcs->[0]->epoch, Date::Utility->new('2012-07-07')->epoch, 'time match');
        is($ohlcs->[0]->open,  100.1,                                   'open match');
        is($ohlcs->[0]->high,  100.1,                                   'high match');
        is($ohlcs->[0]->low,   100.1,                                   'low match');
        is($ohlcs->[0]->close, 100.1,                                   'close match');
    };

    subtest 'second ohlc - from OHLC daily table' => sub {
        is($ohlcs->[1]->epoch, Date::Utility->new('2012-07-08')->epoch, 'time match');
        is($ohlcs->[1]->open,  100.2,                                   'open match');
        is($ohlcs->[1]->high,  103.2,                                   'high match');
        is($ohlcs->[1]->low,   97.7,                                    'low match');
        is($ohlcs->[1]->close, 100.7,                                   'close match');
    };

    subtest 'third ohlc - from OHLC daily table' => sub {
        is($ohlcs->[2]->epoch, Date::Utility->new('2012-07-09')->epoch, 'time match');
        is($ohlcs->[2]->open,  100.8,                                   'open match');
        is($ohlcs->[2]->high,  100.9,                                   'high match');
        is($ohlcs->[2]->low,   100.8,                                   'low match');
        is($ohlcs->[2]->close, 100.9,                                   'close match');
    };

    subtest 'forth ohlc - from OHLC daily table' => sub {
        is($ohlcs->[3]->epoch, Date::Utility->new('2012-07-10')->epoch, 'time match');
        is($ohlcs->[3]->open,  101.0,                                   'open match');
        is($ohlcs->[3]->high,  101.0,                                   'high match');
        is($ohlcs->[3]->low,   101.0,                                   'low match');
        is($ohlcs->[3]->close, 101.0,                                   'close match');
    };

    subtest 'fifth ohlc - from OHLC daily table' => sub {
        is($ohlcs->[4]->epoch, Date::Utility->new('2012-07-11')->epoch, 'time match');
        is($ohlcs->[4]->open,  101.1,                                   'open match');
        is($ohlcs->[4]->high,  101.2,                                   'high match');
        is($ohlcs->[4]->low,   101.1,                                   'low match');
        is($ohlcs->[4]->close, 101.2,                                   'close match');
    };

    subtest 'sixth ohlc - from OHLC daily table' => sub {
        is($ohlcs->[5]->epoch, Date::Utility->new('2012-07-12')->epoch, 'time match');
        is($ohlcs->[5]->open,  101.3,                                   'open match');
        is($ohlcs->[5]->high,  101.3,                                   'high match');
        is($ohlcs->[5]->low,   101.3,                                   'low match');
        is($ohlcs->[5]->close, 101.3,                                   'close match');
    };

    subtest 'seventh ohlc - from OHLC daily table' => sub {
        is($ohlcs->[6]->epoch, Date::Utility->new('2012-07-13')->epoch, 'time match');
        is($ohlcs->[6]->open,  101.4,                                   'open match');
        is($ohlcs->[6]->high,  101.4,                                   'high match');
        is($ohlcs->[6]->low,   101.4,                                   'low match');
        is($ohlcs->[6]->close, 101.4,                                   'close match');
    };

    subtest 'eighth ohlc - from tick table' => sub {
        is($ohlcs->[7]->epoch, Date::Utility->new('2012-07-14')->epoch, 'time match');
        is($ohlcs->[7]->open,  101.5,                                   'open match');
        is($ohlcs->[7]->high,  101.5,                                   'high match');
        is($ohlcs->[7]->low,   101.5,                                   'low match');
        is($ohlcs->[7]->close, 101.5,                                   'close match');
    };
};

