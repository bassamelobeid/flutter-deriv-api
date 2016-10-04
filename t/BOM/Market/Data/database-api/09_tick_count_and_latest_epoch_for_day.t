#!/etc/rmg/bin/perl

use strict;
use warnings;
use utf8;
use Test::More 0.22 tests => 3;
use Test::Exception;
use Test::Warn;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

use Postgres::FeedDB::Spot::DatabaseAPI;
use DateTime;
use Date::Utility;

use Postgres::FeedDB::Spot::DatabaseAPI;
my $dbh = Postgres::FeedDB::read_dbh;
$dbh->{RaiseError} = 1;

my $symbol = 'frxUSDJPY';

subtest 'prepare ticks' => sub {

    my @ticks = ({
            date  => '2012-05-14 05:10:01',
            bid   => 100.0,
            ask   => 100.9,
            quote => 100.6
        },
        {
            date  => '2012-05-15 05:10:01',
            bid   => 100.0,
            ask   => 100.9,
            quote => 100.4
        },
        {
            date  => '2012-05-15 06:10:01',
            bid   => 100.0,
            ask   => 100.9,
            quote => 100.3
        },
        {
            date  => '2012-05-15 07:10:01',
            bid   => 100.0,
            ask   => 100.9,
            quote => 100.8
        },
        {
            date  => '2012-05-15 08:10:01',
            bid   => 100.0,
            ask   => 100.9,
            quote => 100.9
        },
        {
            date  => '2012-05-15 09:10:01',
            bid   => 100.0,
            ask   => 100.9,
            quote => 100.2
        },
        {
            date  => '2012-05-15 10:10:01',
            bid   => 100.0,
            ask   => 100.9,
            quote => 100.5
        },
    );

    foreach my $tick (@ticks) {
        my $date = Date::Utility->new($tick->{date});
        lives_ok {
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
                    underlying => $symbol,
                    epoch      => $date->epoch,
                    quote      => $tick->{quote},
                    bid        => $tick->{bid},
                    ask        => $tick->{ask}});
        }
        'Tick - ' . $tick->{date};
    }
};

subtest 'New tick induction' => sub {
    lives_ok {
        my $date = Date::Utility->new('2012-05-15 12:10:01');
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch => $date->epoch,
            quote => 101.1,
            bid   => 100.2,
            ask   => 100.4
        });
    }
    'Tick - 2012-05-15 12:10:01';
};

subtest 'Next day induction' => sub {
    lives_ok {
        my $date = Date::Utility->new('2012-05-16 05:10:01');
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch => $date->epoch,
            quote => 100.1,
            bid   => 100.2,
            ask   => 100.4
        });
    }
    'Tick - 2012-05-16 05:10:01';
};

