#!/usr/bin/perl

use strict;
use warnings;
use utf8;
use Test::More 0.22 tests => 5;
use Test::Exception;
use Test::NoWarnings;
use Test::Warn;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

use BOM::Market::Data::DatabaseAPI;
use DateTime;
use Date::Utility;

subtest 'Prepare ticks' => sub {
    my @ticks = ({
            date => '2013-01-01 00:00:01',
            bid  => 68.1,
            ask  => 68.3,
            spot => 68.2
        },
        {
            date => '2013-01-01 00:00:03',
            bid  => 69.1,
            ask  => 69.3,
            spot => 69.2
        },
        {
            date => '2013-01-01 00:00:05',
            bid  => 60.1,
            ask  => 60.3,
            spot => 60.2
        },

        {
            date => '2013-01-01 00:00:06',
            bid  => 79.1,
            ask  => 79.3,
            spot => 79.3
        },
        {
            date => '2013-01-01 00:00:07',
            bid  => 77.1,
            ask  => 77.3,
            spot => 77.3
        },
        {
            date => '2013-01-01 00:00:09',
            bid  => 70.1,
            ask  => 70.3,
            spot => 70.3
        },

        {
            date => '2013-01-01 00:00:11',
            bid  => 88.1,
            ask  => 88.3,
            spot => 88.2
        },
        {
            date => '2013-01-01 00:00:13',
            bid  => 89.1,
            ask  => 89.3,
            spot => 89.2
        },
        {
            date => '2013-01-01 00:00:15',
            bid  => 85.1,
            ask  => 85.3,
            spot => 85.2
        },

        {
            date => '2013-01-01 00:00:20',
            bid  => 98.1,
            ask  => 98.3,
            spot => 98.2
        },

        {
            date => '2013-01-01 00:00:32',
            bid  => 108.1,
            ask  => 108.3,
            spot => 108.2
        },
        {
            date => '2013-01-01 00:00:34',
            bid  => 99.3,
            ask  => 99.3,
            spot => 99.2
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
                underlying => 'frxUSDJPY',
                epoch      => $date->ymd . ' ' . $date->hms,
                bid        => $tick->{bid},
                ask        => $tick->{ask},
                quote      => $tick->{spot},
            });
        }
        'tick - ' . $date_time;
    }
};

my $api = BOM::Market::Data::DatabaseAPI->new(underlying => 'frxUSDJPY');

subtest 'get all aggregated ticks' => sub {
    my $start_date          = Date::Utility->new('2013-01-01 00:00:00');
    my $end_date            = Date::Utility->new('2013-01-01 00:00:35');
    my $interval_in_seconds = 5;
    my $ticks;
    lives_ok {
        $ticks = $api->tick_at_for_interval({
            start_date          => $start_date,
            end_date            => $end_date,
            interval_in_seconds => $interval_in_seconds,
        });
    }
    "get ticks_at_for_interval";

    my $validated_ticks = [{
            date => '2013-01-01 00:00:05',
            bid  => 60.1,
            ask  => 60.3,
            spot => 60.2
        },
        {
            date => '2013-01-01 00:00:10',
            bid  => 70.1,
            ask  => 70.3,
            spot => 70.3
        },
        {
            date => '2013-01-01 00:00:15',
            bid  => 85.1,
            ask  => 85.3,
            spot => 85.2
        },
        {
            date => '2013-01-01 00:00:20',
            bid  => 98.1,
            ask  => 98.3,
            spot => 98.2
        },
        {
            date => '2013-01-01 00:00:35',
            bid  => 99.3,
            ask  => 99.3,
            spot => 99.2
        },
    ];

    subtest 'ticks count' => sub {
        is(scalar @{$ticks}, scalar @{$validated_ticks}, 'ticks count match');
    };

    subtest 'Check all aggregated ticks' => sub {
        for (my $i = 0; $i < scalar @{$ticks}; $i++) {
            my $db_tick    = $ticks->[$i];
            my $check_tick = $validated_ticks->[$i];

            is($db_tick->epoch, Date::Utility->new($check_tick->{date})->epoch, 'tick epoch');
            is($db_tick->quote, $check_tick->{spot},                            'quote');
            is($db_tick->bid,   $check_tick->{bid},                             'bid');
            is($db_tick->ask,   $check_tick->{ask},                             'ask');
        }
    };
};

subtest 'get few aggregated ticks' => sub {
    my $start_date          = Date::Utility->new('2013-01-01 00:00:00');
    my $end_date            = Date::Utility->new('2013-01-01 00:00:15');
    my $interval_in_seconds = 5;
    my $ticks;
    lives_ok {
        $ticks = $api->tick_at_for_interval({
            start_date          => $start_date,
            end_date            => $end_date,
            interval_in_seconds => $interval_in_seconds,
        });
    }
    "get ticks_at_for_interval";

    subtest 'ticks count' => sub {
        is(scalar @{$ticks}, 3, 'ticks count match');
    };
};

subtest 'no available ticks' => sub {
    my $start_date          = Date::Utility->new('2013-01-02 00:00:00');
    my $end_date            = Date::Utility->new('2013-01-03 00:00:00');
    my $interval_in_seconds = 5;
    my $ticks;
    lives_ok {
        $ticks = $api->tick_at_for_interval({
            start_date          => $start_date,
            end_date            => $end_date,
            interval_in_seconds => $interval_in_seconds,
        });
    }
    "get ticks_at_for_interval";

    subtest 'ticks count' => sub {
        is(scalar @{$ticks}, 0, 'ticks count match');
    };
};
