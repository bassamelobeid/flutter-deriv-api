#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;

use Date::Utility;
use BOM::Product::Contract::PredefinedParameters qw(generate_predefined_offerings);

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

my $supported_symbol = 'frxUSDJPY';
my $monday           = Date::Utility->new('2016-11-14');    # monday

subtest 'non trading day' => sub {
    my $saturday = Date::Utility->new('2016-11-19');                               # saturday
    my $offerings = generate_predefined_offerings($supported_symbol, $saturday);
    ok !@$offerings, 'no offerings were generated on non trading day';
    setup_ticks($monday, $supported_symbol);
    $offerings = generate_predefined_offerings($supported_symbol, $monday);
    ok @$offerings, 'generates predefined offerings on a trading day';
};

subtest 'intraday trading period' => sub {
    # 0 - underlying symbol
    # 1 - expected contract category
    # 2 - generation time
    # 3 - expected offerings count
    # 4 - expected trading periods (order matters)
    my @test_inputs = (
        # monday at 00:00GMT
        [
            'frxUSDJPY', 'callput', '2016-11-14 00:00:00',
            2, [['2016-11-14 00:00:00', '2016-11-14 02:00:00'], ['2016-11-14 00:00:00', '2016-11-14 02:00:00']]
        ],
        # monday at 00:44GMT
        [
            'frxUSDJPY', 'callput', '2016-11-14 00:44:00',
            2, [['2016-11-14 00:00:00', '2016-11-14 02:00:00'], ['2016-11-14 00:00:00', '2016-11-14 02:00:00']]
        ],
        # monday at 00:45GMT
        [
            'frxUSDJPY',
            'callput',
            '2016-11-14 00:45:00',
            4,
            [
                ['2016-11-14 00:00:00', '2016-11-14 02:00:00'],
                ['2016-11-14 00:45:00', '2016-11-14 06:00:00'],
                ['2016-11-14 00:00:00', '2016-11-14 02:00:00'],
                ['2016-11-14 00:45:00', '2016-11-14 06:00:00']]
        ],
        # monday at 01:45GMT
        [
            'frxUSDJPY',
            'callput',
            '2016-11-14 01:45:00',
            6,
            [
                ['2016-11-14 00:00:00', '2016-11-14 02:00:00'],
                ['2016-11-14 01:45:00', '2016-11-14 04:00:00'],
                ['2016-11-14 00:45:00', '2016-11-14 06:00:00'],
                ['2016-11-14 00:00:00', '2016-11-14 02:00:00'],
                ['2016-11-14 01:45:00', '2016-11-14 04:00:00'],
                ['2016-11-14 00:45:00', '2016-11-14 06:00:00']]
        ],
        # monday at 02:00GMT
        [
            'frxUSDJPY',
            'callput',
            '2016-11-14 02:00:00',
            4,
            [
                ['2016-11-14 01:45:00', '2016-11-14 04:00:00'],
                ['2016-11-14 00:45:00', '2016-11-14 06:00:00'],
                ['2016-11-14 01:45:00', '2016-11-14 04:00:00'],
                ['2016-11-14 00:45:00', '2016-11-14 06:00:00']]
        ],
        # monday at 18:00GMT
        ['frxUSDJPY', 'callput', '2016-11-14 18:00:00', 0, [],],
        # monday at 21:44GMT
        ['frxUSDJPY', 'callput', '2016-11-14 21:44:00', 0, [],],
        # monday at 21:45GMT
        [
            'frxUSDJPY', 'callput', '2016-11-14 21:45:00',
            2, [['2016-11-14 21:45:00', '2016-11-14 23:59:59'], ['2016-11-14 21:45:00', '2016-11-14 23:59:59'],],
        ],
        # monday at 21:45GMT
        ['frxGBPJPY', 'callput', '2016-11-14 21:45:00', 0, [],],
    );

    foreach my $input (@test_inputs) {
        my ($symbol, $category, $date, $count, $periods) = map { $input->[$_] } (0 .. 4);
        $date = Date::Utility->new($date);
        setup_ticks($date, $symbol);
        note('generating for ' . $symbol . '. Time set to ' . $date->day_as_string . ' at ' . $date->time);
        my $offerings = generate_predefined_offerings($symbol, $date);
        my @intraday = grep { $_->{expiry_type} eq 'intraday' } @$offerings;
        is scalar(@intraday), $count, 'expected two offerings on intraday at 00:00GMT';

        if ($count == 0 and scalar(@intraday) == 0) {
            pass('no intraday offerings found for ' . $symbol);
        } else {
            for (0 .. $#intraday) {
                my $got      = $intraday[$_];
                my $expected = $periods->[$_];
                like $got->{contract_category}, qr/$category/, 'valid contract category ' . $category;
                is $got->{trading_period}->{date_start}->{date},  $expected->[0], 'period starts at ' . $expected->[0];
                is $got->{trading_period}->{date_expiry}->{date}, $expected->[1], 'period ends at ' . $expected->[1];
            }
        }
    }
};

sub setup_ticks {
    my ($date, $symbol, $quote) = @_;

    BOM::Test::Data::Utility::FeedTestDatabase->instance->truncate_tables();
    my $first_tick_time = Date::Utility->new($date)->minus_time_interval('100d');
    my $now             = Date::Utility->new($date);
    for ($first_tick_time, $now) {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => $symbol,
            epoch      => $_->epoch,
            $quote ? (quote => $quote) : (),
        });
    }
}

done_testing();
