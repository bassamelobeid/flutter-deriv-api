#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More;

use LandingCompany::Offerings qw(get_offerings_with_filter reinitialise_offerings);
use BOM::Platform::Runtime;

subtest 'quant suspend trade' => sub {
    my $offerings_cfg = BOM::Platform::Runtime->instance->get_offerings_config;
    reinitialise_offerings($offerings_cfg);
    my @u = get_offerings_with_filter($offerings_cfg, 'underlying_symbol', {market => 'forex'});
    ok grep { $_ eq 'frxUSDJPY' } @u;

    my $orig = BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_trades;
    BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_trades(['frxUSDJPY']);
    reinitialise_offerings(BOM::Platform::Runtime->instance->get_offerings_config);
    $offerings_cfg = BOM::Platform::Runtime->instance->get_offerings_config;
    @u = get_offerings_with_filter($offerings_cfg, 'underlying_symbol', {market => 'forex'});
    ok !grep { $_ eq 'frxUSDJPY' } @u;

    BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_trades($orig);
};

subtest 'quant suspend buy' => sub {
    my $offerings_cfg = BOM::Platform::Runtime->instance->get_offerings_config;
    reinitialise_offerings($offerings_cfg);
    my @u = get_offerings_with_filter($offerings_cfg, 'underlying_symbol', {market => 'forex'});
    ok grep { $_ eq 'frxUSDJPY' } @u;

    my $orig = BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_buy;
    BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_buy(['frxUSDJPY']);
    reinitialise_offerings(BOM::Platform::Runtime->instance->get_offerings_config);
    $offerings_cfg = BOM::Platform::Runtime->instance->get_offerings_config;
    @u = get_offerings_with_filter($offerings_cfg, 'underlying_symbol', {market => 'forex'});
    ok !grep { $_ eq 'frxUSDJPY' } @u;

    BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_buy($orig);
};

subtest 'suspend on Japan' => sub {
    my $offerings_cfg = BOM::Platform::Runtime->instance->get_offerings_config;
    reinitialise_offerings($offerings_cfg);
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
    reinitialise_offerings(BOM::Platform::Runtime->instance->get_offerings_config);

    $offerings_cfg = BOM::Platform::Runtime->instance->get_offerings_config;
    @u             = get_offerings_with_filter(
        $offerings_cfg,
        'underlying_symbol',
        {
            market          => 'forex',
            landing_company => 'japan'
        });
    ok !grep { $_ eq 'frxUSDJPY' } @u;
};

done_testing;
