#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 4;
use Test::NoWarnings;

use BOM::Product::Offerings qw(get_offerings_with_filter);
use BOM::Platform::Runtime;

subtest 'quant suspend trade' => sub {
    my @u = get_offerings_with_filter('underlying_symbol',{market => 'forex'});
    ok grep {$_ eq 'frxUSDJPY'} @u;
    my $orig = BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_trades;
    BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_trades(['frxUSDJPY']);
    BOM::Product::Offerings::_flush_offerings();
    @u = get_offerings_with_filter('underlying_symbol',{market => 'forex'});
    ok !grep {$_ eq 'frxUSDJPY'} @u;
    BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_trades($orig);
    BOM::Product::Offerings::_flush_offerings();
};

subtest 'quant suspend buy' => sub {
    my @u = get_offerings_with_filter('underlying_symbol',{market => 'forex'});
    ok grep {$_ eq 'frxUSDJPY'} @u;
    my $orig = BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_buy;
    BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_buy(['frxUSDJPY']);
    BOM::Product::Offerings::_flush_offerings();
    @u = get_offerings_with_filter('underlying_symbol',{market => 'forex'});
    ok !grep {$_ eq 'frxUSDJPY'} @u;
    BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_buy($orig);
    BOM::Product::Offerings::_flush_offerings();
};

subtest 'suspend on Japan' => sub {
    my @u = get_offerings_with_filter('underlying_symbol',{market => 'forex', landing_company => 'japan'});
    ok grep {$_ eq 'frxUSDJPY'} @u;
    my $orig = BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_buy;
    BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_buy(['frxUSDJPY']);
    BOM::Product::Offerings::_flush_offerings();
    @u = get_offerings_with_filter('underlying_symbol',{market => 'forex'});
    ok !grep {$_ eq 'frxUSDJPY'} @u;
    BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_buy($orig);
    BOM::Product::Offerings::_flush_offerings();
};
