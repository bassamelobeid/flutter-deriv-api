#!/etc/rmg/bin/perl

use strict;
use warnings;
use utf8;
use Test::More 0.22 tests => 5;
use Test::Exception;
use Test::NoWarnings;
use Test::Warn;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

use Quant::Framework::Spot::DatabaseAPI;
use DateTime;
use Date::Utility;

use Quant::Framework::Spot::DatabaseAPI;
my $dbh = BOM::Database::FeedDB::read_dbh;
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

subtest 'Basic test' => sub {
    my $api = Quant::Framework::Spot::DatabaseAPI->new(underlying => $symbol, dbh => $dbh);

    subtest 'Ideal date 2012-05-15' => sub {
        my $output = $api->combined_realtime_tick({
            start_time => '2012-05-15 00:00:00',
            end_time   => '2012-05-15 11:00:00'
        });
        isa_ok $output, 'Quant::Framework::Spot::Tick';
        ok $output->epoch, 'Has epoch';
        my $date = Date::Utility->new({epoch => $output->epoch});
        is $date->datetime_yyyymmdd_hhmmss, '2012-05-15 10:10:01', 'Date Ok';
        is $output->quote, 100.5, 'close';
    };

    subtest 'shorter time frame for 2012-05-15' => sub {
        my $output = $api->combined_realtime_tick({
            start_time => '2012-05-15 06:00:00',
            end_time   => '2012-05-15 09:00:00'
        });
        isa_ok $output, 'Quant::Framework::Spot::Tick';
        ok $output->epoch, 'Has epoch';
        my $date = Date::Utility->new({epoch => $output->epoch});
        is $date->datetime_yyyymmdd_hhmmss, '2012-05-15 08:10:01', 'Date Ok';
        is $output->quote, 100.9, 'close';
    };

    subtest 'Day before 2012-05-14' => sub {
        my $output = $api->combined_realtime_tick({
            start_time => '2012-05-14 00:00:00',
            end_time   => '2012-05-14 20:00:00'
        });
        isa_ok $output, 'Quant::Framework::Spot::Tick';
        ok $output->epoch, 'Has epoch';
        my $date = Date::Utility->new({epoch => $output->epoch});
        is $date->datetime_yyyymmdd_hhmmss, '2012-05-14 05:10:01', 'Date Ok';
        is $output->quote, 100.6, 'close';
    };

    subtest 'Day after 2012-05-16' => sub {
        my $output = $api->combined_realtime_tick({
            start_time => '2012-05-16 01:00:00',
            end_time   => '2012-05-16 20:00:00'
        });
        is $output, undef, "Tick is not defined";
    };
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

    my $api = Quant::Framework::Spot::DatabaseAPI->new(underlying => $symbol, dbh => $dbh);

    my $output = $api->combined_realtime_tick({
        start_time => '2012-05-15 00:00:00',
        end_time   => '2012-05-15 15:00:00'
    });
    isa_ok $output, 'Quant::Framework::Spot::Tick';
    ok $output->epoch, 'Has epoch';
    my $date = Date::Utility->new({epoch => $output->epoch});
    is $date->datetime_yyyymmdd_hhmmss, '2012-05-15 12:10:01', 'Date Ok - Last tick counted';
    is $output->quote, 101.1, 'close';
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

    my $api = Quant::Framework::Spot::DatabaseAPI->new(underlying => $symbol, dbh => $dbh);

    subtest 'Date 2012-05-15' => sub {
        my $output = $api->combined_realtime_tick({
            start_time => '2012-05-15 00:00:00',
            end_time   => '2012-05-15 23:00:00'
        });
        isa_ok $output, 'Quant::Framework::Spot::Tick';
        ok $output->epoch, 'Has epoch';
        my $date = Date::Utility->new({epoch => $output->epoch});
        is $date->datetime_yyyymmdd_hhmmss, '2012-05-15 12:10:01', 'Date Ok';
    };

    subtest 'Date 2012-05-16' => sub {
        my $output = $api->combined_realtime_tick({
            start_time => '2012-05-16 00:00:00',
            end_time   => '2012-12-06 23:00:00'
        });
        isa_ok $output, 'Quant::Framework::Spot::Tick';
        ok $output->epoch, 'Has epoch';
        my $date = Date::Utility->new({epoch => $output->epoch});
        is $date->datetime_yyyymmdd_hhmmss, '2012-05-16 05:10:01', 'Date Ok';
        is $output->quote, 100.1, 'close';
    };
};

