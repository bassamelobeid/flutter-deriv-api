#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use LandingCompany::Offerings qw(get_offerings_with_filter reinitialise_offerings);
use BOM::Platform::Runtime;

my $offerings_config = BOM::Platform::Runtime->instance->get_offerings_config;

subtest 'test offerings' => sub {
    my $symbol = 'frxUSDJPY';
    my $rt     = BOM::Platform::Runtime->instance->app_config->quants->underlyings;
    test_offerings('underlying_symbol', 'frxUSDJPY', 'suspend_trades',                    $rt, 'suspend trades');
    test_offerings('underlying_symbol', 'frxUSDJPY', 'suspend_buy',                       $rt, 'suspend buy');
    test_offerings('underlying_symbol', 'frxUSDJPY', 'disabled_due_to_corporate_actions', $rt, 'disable due to corporate action');
    test_offerings('market', 'forex', 'disabled', BOM::Platform::Runtime->instance->app_config->quants->markets, 'disable market');
    test_offerings(
        'contract_type', 'CALL', 'suspend_contract_types',
        BOM::Platform::Runtime->instance->app_config->quants->features,
        'disable contract type'
    );

};

sub test_offerings {
    my ($seek, $symbol, $type, $path, $name) = @_;
    note("testing $name");
    my $orig = $path->$type();
    $path->$type([$symbol]);
    $offerings_config = BOM::Platform::Runtime->instance->get_offerings_config;
    reinitialise_offerings($offerings_config);

    my %s = map { $_ => 1 } get_offerings_with_filter($offerings_config, $seek);
    ok !$s{$symbol}, "$symbol is not offered";


    $path->$type($orig);
    $offerings_config = BOM::Platform::Runtime->instance->get_offerings_config;
    reinitialise_offerings($offerings_config);

    %s = map { $_ => 1 } get_offerings_with_filter($offerings_config, $seek);
    ok $s{$symbol}, "$symbol is offered";
    $path->$type($orig);
    $offerings_config = BOM::Platform::Runtime->instance->get_offerings_config;
    reinitialise_offerings($offerings_config);
}
done_testing();
