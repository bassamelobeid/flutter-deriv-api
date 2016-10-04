#!/etc/rmg/bin/perl

use strict;
use warnings;
use utf8;
use Test::More 0.22 tests => 6;
use Test::Exception;
use Test::Warn;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use Postgres::FeedDB::Spot::DatabaseAPI;
use DateTime;
use Date::Utility;

my $dbh = BOM::Database::FeedDB::read_dbh;
$dbh->{RaiseError} = 1;

subtest 'No Ticks' => sub {
    my $api = Postgres::FeedDB::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);
    my $tick;
    lives_ok {
        $tick = $api->tick_after('2012-05-13 05:10:01');
    }
    'No tick after';

    ok !$tick, 'No Tick';
};

subtest 'Tick before request time' => sub {
    lives_ok {
        my $date = DateTime->new(
            year   => 2012,
            month  => 5,
            day    => 13,
            hour   => 5,
            minute => 10
        );
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch => $date->epoch,
            quote => 79.873,
            bid   => 100.2,
            ask   => 100.4
        });
    }
    'Tick 1 - 2012-05-13 05:10:00';

    my $api = Postgres::FeedDB::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);
    my $tick;
    lives_ok {
        $tick = $api->tick_after('2012-05-13 05:10:01');
    }
    'No tick after';

    ok !$tick, 'No Tick';
};

subtest 'Tick at request time' => sub {
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

    my $api = Postgres::FeedDB::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);
    my $tick;
    lives_ok {
        $tick = $api->tick_after('2012-05-13 05:10:01');
    }
    'No tick after';

    ok !$tick, 'No Tick';
};

subtest 'Tick after request time' => sub {
    lives_ok {
        my $date = DateTime->new(
            year   => 2012,
            month  => 5,
            day    => 13,
            hour   => 5,
            minute => 10,
            second => 30
        );
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch => $date->epoch,
            quote => 79.873,
            bid   => 100.2,
            ask   => 100.4
        });
    }
    'Tick 1 - 2012-05-13 05:10:30';

    my $api = Postgres::FeedDB::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);
    my $tick;
    lives_ok {
        $tick = $api->tick_after('2012-05-13 05:10:01');
    }
    'Tick after';

    ok $tick, 'There is a tick';
    my $date = Date::Utility->new({epoch => $tick->epoch});
    is $date->datetime_yyyymmdd_hhmmss, '2012-05-13 05:10:30', 'Correct date';
    is $tick->quote, 79.873, 'Correct quote';
};

subtest 'Invert' => sub {
    my $api = Postgres::FeedDB::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);
    my $tick;
    lives_ok {
        $tick = $api->tick_after('2012-05-13 05:10:01');
    }
    'Tick after';

    ok $tick, 'There is a tick';
    ok $tick->invert_values, 'We succesfully inverted';

    is $tick->quote, (1 / 79.873), 'Inverted Quote';
    is $tick->bid,   (1 / 100.2),  'Inverted bid';
    is $tick->ask,   (1 / 100.4),  'Inverted ask';
};

subtest 'Tick much later' => sub {
    lives_ok {
        my $date = DateTime->new(
            year   => 2012,
            month  => 5,
            day    => 13,
            hour   => 5,
            minute => 10,
            second => 38
        );
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch => $date->epoch,
            quote => 79.873,
            bid   => 100.2,
            ask   => 100.4
        });
    }
    'Tick 1 - 2012-05-13 05:10:30';

    my $api = Postgres::FeedDB::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);
    my $tick;
    lives_ok {
        $tick = $api->tick_after('2012-05-13 05:10:01');
    }
    'Tick after';

    ok $tick, 'There is a tick';
    my $date = Date::Utility->new({epoch => $tick->epoch});
    is $date->datetime_yyyymmdd_hhmmss, '2012-05-13 05:10:30', 'Correct date';
    is $tick->quote, 79.873, 'Correct quote';
};
