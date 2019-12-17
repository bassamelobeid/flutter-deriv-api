#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use BOM::Product::ContractFactory qw(produce_contract);

subtest 'allowed_slippage' => sub {
    my $args = {
        bet_type   => 'CALL',
        underlying => 'frxUSDJPY',
        barrier    => 'S0P',
        duration   => '1h',
        payout     => 100,
        currency   => 'USD',
    };
    my $c = produce_contract($args);
    my $pricing_hour = Date::Utility->new;
    my $fx_slippage = ($pricing_hour->hour >= 6 and $pricing_hour->hour <= 16) ? 0.015 : 0.0175;
    is ($c->allowed_slippage, $fx_slippage, 'slippage is ' . $fx_slippage);
    $args->{underlying} = 'R_10';
    $c = produce_contract($args);
    is $c->allowed_slippage, 0.006, 'slippage is 0.6%';
};

done_testing();
