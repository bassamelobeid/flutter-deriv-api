#!/usr/bin/perl

use strict;
use warnings;
use Test::More tests => 6;
use Test::Exception;
use Test::NoWarnings;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use Date::Utility;
use BOM::MarketData::VolSurface::Utils;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Market::Underlying;
initialize_realtime_ticks_db();
my $now = Date::Utility->new;
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'partial_trading',
    {
        type => 'early_closes',
        recorded_date => $now,
        calendar => {
            '24-Dec-2015' => {
                '18h00m' => ['FOREX'],
            },
            '31-Dec-2015' => {
                '18h00m' => ['FOREX'],
            },
            '18-Jan-2016' => {
                '18h00m' => ['FOREX'],
            },
        },
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'USD',
        recorded_date => $now,
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'JPY',
        recorded_date => $now,
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now,
    });
my $exchange = BOM::Market::Underlying->new('frxUSDJPY')->exchange;
subtest 'vol_cutoff_from_thurs_to_sat_on_non_dst' => sub {
    my $date_start = Date::Utility->new('2016-01-07 00:00:00');
    my $c = produce_contract('CALL_FRXUSDJPY_10_' . $date_start->epoch . '_' . $date_start->plus_time_interval('7d')->epoch . 'F_120050000_0', 'USD');
    my $p = $c->build_parameters;
    compare_cut_off($date_start, 5, $p, $exchange);
};
subtest 'vol_cutoff_from_thurs_to_sat_on_dst' => sub {
    my $date_start = Date::Utility->new('2015-10-29 00:00:00');
    my $c = produce_contract('CALL_FRXUSDJPY_10_' . $date_start->epoch . '_' . $date_start->plus_time_interval('7d')->epoch . 'F_120050000_0', 'USD');
    my $p = $c->build_parameters;
    compare_cut_off($date_start, 5, $p, $exchange);
};

subtest 'vol_cutoff_during_christmas' => sub {
    my $date_start = Date::Utility->new('2015-12-23 00:00:00');
    my $c = produce_contract('CALL_FRXUSDJPY_10_' . $date_start->epoch . '_' . $date_start->plus_time_interval('7d')->epoch . 'F_120050000_0', 'USD');
    my $p = $c->build_parameters;
    compare_cut_off($date_start, 5, $p, $exchange);
};

subtest 'vol_cutoff_during_new_year' => sub {
    my $date_start = Date::Utility->new('2015-12-30 00:00:00');
    my $c = produce_contract('CALL_FRXUSDJPY_10_' . $date_start->epoch . '_' . $date_start->plus_time_interval('7d')->epoch . 'F_120050000_0', 'USD');
    my $p = $c->build_parameters;
    compare_cut_off($date_start, 5, $p, $exchange);
};

subtest 'vol_cutoff_during_early_close' => sub {
    my $date_start = Date::Utility->new('2016-01-15 00:00:00');
    my $c = produce_contract('CALL_FRXUSDJPY_10_' . $date_start->epoch . '_' . $date_start->plus_time_interval('7d')->epoch . 'F_120050000_0', 'USD');
    my $p = $c->build_parameters;
    compare_cut_off($date_start, 5, $p, $exchange);
};


sub compare_cut_off {
    my ($date_start, $no_of_day, $pricing_param, $exchange) = @_;
    my $vol_utils = BOM::MarketData::VolSurface::Utils->new;

    for (my $i = -1; $i < $no_of_day * 24; $i++) {
        my $date_pricing  = $date_start->plus_time_interval($i . 'h');
        my $rollover_date = $vol_utils->NY1700_rollover_date_on($date_pricing);
        $pricing_param->{date_pricing} = $date_pricing;
        my $new_contract = produce_contract($pricing_param);
        my $expected_cutoff =
            ($exchange->trades_on($date_pricing) and $date_pricing->epoch < $rollover_date->epoch)
            ? $exchange->closing_on($date_pricing)->time_cutoff
            : $exchange->closing_on($exchange->trade_date_after($date_pricing))->time_cutoff;

        is($new_contract->volsurface->cutoff->code, $expected_cutoff,
                  'For '
                . $date_pricing->datetime
                . " Expected_cutoff:[$expected_cutoff] Actual_cutoff:["
                . $new_contract->volsurface->cutoff->code
                . "]\n");
    }

}
