#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 3;

use LandingCompany::Offerings qw(get_offerings_with_filter);
use BOM::Platform::Runtime;

my $offerings_cfg = BOM::Platform::Runtime->instance->get_offerings_config;

subtest 'quant suspend trade' => sub {
    my @u = get_offerings_with_filter($offerings_cfg, 'underlying_symbol', {market => 'forex'});
    ok grep { $_ eq 'frxUSDJPY' } @u;
    my $orig = BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_trades;
    BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_trades(['frxUSDJPY']);
    LandingCompany::Offerings::_flush_offerings();
    $offerings_cfg = BOM::Platform::Runtime->instance->get_offerings_config;
    @u = get_offerings_with_filter($offerings_cfg, 'underlying_symbol', {market => 'forex'});
    ok !grep { $_ eq 'frxUSDJPY' } @u;
    BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_trades($orig);
    LandingCompany::Offerings::_flush_offerings();
    $offerings_cfg = BOM::Platform::Runtime->instance->get_offerings_config;
};

subtest 'quant suspend buy' => sub {
    my @u = get_offerings_with_filter($offerings_cfg, 'underlying_symbol', {market => 'forex'});
    ok grep { $_ eq 'frxUSDJPY' } @u;
    my $orig = BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_buy;
    BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_buy(['frxUSDJPY']);
    LandingCompany::Offerings::_flush_offerings();
    $offerings_cfg = BOM::Platform::Runtime->instance->get_offerings_config;
    @u = get_offerings_with_filter($offerings_cfg, 'underlying_symbol', {market => 'forex'});
    ok !grep { $_ eq 'frxUSDJPY' } @u;
    BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_buy($orig);
    LandingCompany::Offerings::_flush_offerings();
    $offerings_cfg = BOM::Platform::Runtime->instance->get_offerings_config;
};

subtest 'suspend on Japan' => sub {
    my @u = get_offerings_with_filter(
        $offerings_cfg,
        'underlying_symbol',
        {
            market          => 'forex',
            landing_company => 'japan'
        });
    ok grep { $_ eq 'frxUSDJPY' } @u;
    my $orig = BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_buy;
    BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_buy(['frxUSDJPY']);
    LandingCompany::Offerings::_flush_offerings();
    $offerings_cfg = BOM::Platform::Runtime->instance->get_offerings_config;
    @u = get_offerings_with_filter(
        $offerings_cfg,
        'underlying_symbol',
        {
            market          => 'forex',
            landing_company => 'japan'
        });
    ok !grep { $_ eq 'frxUSDJPY' } @u;
    BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_buy($orig);
    LandingCompany::Offerings::_flush_offerings();
};
