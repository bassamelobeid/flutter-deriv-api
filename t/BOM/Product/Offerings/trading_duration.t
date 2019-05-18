#!/usr/bin/perl

use strict;
use warnings;
use Test::MockTime qw(set_absolute_time);
use Test::More;
use Test::Deep;
use Test::FailWarnings;
use Date::Utility;
use BOM::Product::Offerings::TradingDuration qw(generate_trading_durations);
use BOM::Config::Runtime;
use LandingCompany::Registry;
use YAML::XS qw(LoadFile);

# suspend based on what we are currently suspend on system.
BOM::Config::Runtime->instance->app_config->quants->underlyings->suspend_buy([
    'DJI',  'frxAUDPLN', 'JCI',    'AS51', 'BSESENSEX30', 'HSI',  'N225', 'STI',   'BFX', 'AEX',
    'FCHI', 'GDAXI',     'ISEQ',   'OBX',  'SPTSX60',     'SSMI', 'SPC',  'DFMGI', 'JCI', 'TOP40',
    'DJI',  'FTSE',      'IBEX35', 'SX5E', 'NDX',         'frxGBPPLN'
]);
subtest 'trading durations at quiet period' => sub {
    set_absolute_time(Date::Utility->new('2019-04-12 01:00:00')->epoch);
    my $offerings = LandingCompany::Registry::get('svg')->basic_offerings(BOM::Config::Runtime->instance->get_offerings_config);

    my $trading_durations = generate_trading_durations($offerings);
    my $expected          = LoadFile('t/BOM/Product/Offerings/expected_trading_durations_quiet_period.yml');
    is_deeply($trading_durations, $expected);
};

subtest 'trading durations' => sub {
    set_absolute_time(Date::Utility->new('2019-04-12 08:00:00')->epoch);
    my $offerings = LandingCompany::Registry::get('svg')->basic_offerings(BOM::Config::Runtime->instance->get_offerings_config);

    my $trading_durations = generate_trading_durations($offerings);
    my $expected          = LoadFile('t/BOM/Product/Offerings/expected_trading_durations.yml');
    is_deeply($trading_durations, $expected);
};

done_testing();
