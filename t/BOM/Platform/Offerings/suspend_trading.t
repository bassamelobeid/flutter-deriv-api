#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use BOM::Platform::Offerings qw(get_offerings_with_filter);
use BOM::Platform::Runtime;

subtest 'test offerings' => sub {
    my $symbol = 'frxUSDJPY';
    my $rt     = BOM::Platform::Runtime->instance->app_config->quants->underlyings;
    test_offerings('underlying_symbol', 'frxUSDJPY', 'suspend_trades',                    $rt, 'suspend trades');
    test_offerings('underlying_symbol', 'frxUSDJPY', 'suspend_buy',                       $rt, 'suspend buy');
    test_offerings('underlying_symbol', 'frxUSDJPY', 'disabled_due_to_corporate_actions', $rt, 'disable due to corporate action');
    test_offerings('market', 'forex', 'disabled', BOM::Platform::Runtime->instance->app_config->quants->markets, 'disable market');
    test_offerings(
        'contract_type', 'CALL', 'suspend_claim_types',
        BOM::Platform::Runtime->instance->app_config->quants->features,
        'disable contract type'
    );

};

sub test_offerings {
    my ($seek, $symbol, $type, $path, $name) = @_;
    my $offerings_cfg = BOM::Platform::Runtime->instance->get_offerings_config;

    note("testing $name");
    my $orig = $path->$type();
    $path->$type([$symbol]);
    BOM::Platform::Offerings::_flush_offerings();
    my %s = map { $_ => 1 } get_offerings_with_filter($offerings_cfg, $seek);
    ok !$s{$symbol}, "$symbol is not offered";
    $path->$type($orig);
    BOM::Platform::Offerings::_flush_offerings();
    %s = map { $_ => 1 } get_offerings_with_filter($offerings_cfg, $seek);
    ok $s{$symbol}, "$symbol is offered";
    $path->$type($orig);
}
done_testing();
