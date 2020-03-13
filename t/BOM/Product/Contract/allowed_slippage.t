#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use BOM::Product::ContractFactory qw(produce_contract);
use Date::Utility;

subtest 'allowed_slippage' => sub {
    my $args = {
        bet_type     => 'CALL',
        underlying   => 'frxUSDJPY',
        barrier      => 'S0P',
        duration     => '1h',
        payout       => 100,
        currency     => 'USD',
        date_start   => Date::Utility->new('2019-12-9 10:00:00'),
        date_pricing => Date::Utility->new('2019-12-9 10:00:00'),
    };
    my $c = produce_contract($args);
    is ($c->allowed_slippage, 0.015, 'slippage is ' . 0.015);
    $args->{underlying} = 'R_10';
    $c = produce_contract($args);
    is $c->allowed_slippage, 0.006, 'slippage is 0.6%';
};

done_testing();
