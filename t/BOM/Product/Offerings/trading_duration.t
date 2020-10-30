#!/usr/bin/perl

use strict;
use warnings;
use Test::MockTime qw(set_absolute_time);
use BOM::Test;
use Test::More;
use Test::Deep;
use Test::FailWarnings;
use Date::Utility;
use BOM::Product::Offerings::TradingDuration qw(generate_trading_durations);
use BOM::Config::Runtime;
use LandingCompany::Registry;
use YAML::XS qw(LoadFile);

# suspend based on what we are currently suspend on system.
BOM::Config::Runtime->instance->app_config->quants->underlyings->suspend_buy(
    ['frxAUDPLN', 'frxGBPPLN', '1HZ100V', '1HZ10V', '1HZ25V', '1HZ50V', '1HZ75V']);
subtest 'trading durations at quiet period' => sub {
    set_absolute_time(Date::Utility->new('2019-04-12 01:00:00')->epoch);
    my $offerings = LandingCompany::Registry::get('virtual')->basic_offerings(BOM::Config::Runtime->instance->get_offerings_config);

    my $trading_durations = generate_trading_durations($offerings);
    my $expected          = LoadFile('t/BOM/Product/Offerings/expected_trading_durations_quiet_period.yml');
    is_deeply($trading_durations, $expected);
};

subtest 'trading durations' => sub {
    set_absolute_time(Date::Utility->new('2019-04-12 08:00:00')->epoch);
    my $offerings = LandingCompany::Registry::get('virtual')->basic_offerings(BOM::Config::Runtime->instance->get_offerings_config);

    my $trading_durations = generate_trading_durations($offerings);
    my $expected          = LoadFile('t/BOM/Product/Offerings/expected_trading_durations.yml');
    is_deeply($trading_durations, $expected);
};

done_testing();
