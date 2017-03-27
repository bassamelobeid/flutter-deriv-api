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
    is $c->allowed_slippage, 0.0175, 'slippage is 1.75%';
    $args->{underlying} = 'R_10';
    $c = produce_contract($args);
    is $c->allowed_slippage, 0.01, 'slippage is 1%';
};

done_testing();
