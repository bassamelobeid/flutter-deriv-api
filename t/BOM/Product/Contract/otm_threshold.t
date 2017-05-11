#!/usr/bin/perl

use Test::More;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Platform::Runtime;

subtest 'otm_threshold' => sub {
    my $ori = BOM::Platform::Runtime->instance->app_config->quants->custom_otm_threshold;
    BOM::Platform::Runtime->instance->app_config->quants->custom_otm_threshold(
        '{"xxx": {"conditions": {"underlying_symbol": "frxUSDJPY", "expiry_type": "daily"}, "value": "0.01"}, "yyy": {"conditions": {"market": "forex", "expiry_type": "daily"}, "value": "0.05"}}'
    );
    my $c = produce_contract({
        underlying => 'frxUSDJPY',
        bet_type   => 'CALL',
        barrier    => 'S0P',
        currency   => 'USD',
        payout     => 10,
        duration   => '1d',
    });
    is $c->otm_threshold, 0.01, 'returns underlying level otm threshold of 0.01, if both market and underlying level matches.';
    $c->clear_otm_threshold;
    BOM::Platform::Runtime->instance->app_config->quants->custom_otm_threshold(
        '{"xxx": {"conditions": {"underlying_symbol": "frxUSDJPY", "expiry_type": "daily"}, "value": "0.01"}, "yyy": {"conditions": {"market": "forex", "expiry_type": "daily"}, "value": "0.05"}, "zzz": {"conditions": {"underlying_symbol": "frxUSDJPY", "is_atm_bet": "1"}, "value": "0.5"}}'
    );
    is $c->otm_threshold, 0.5, 'returns the max if two conditions on the underlying level matches.';
};

done_testing();
