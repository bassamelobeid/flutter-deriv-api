#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;

use BOM::Product::ContractFactory qw(produce_contract);
use LandingCompany::Registry;

my $offerings = LandingCompany::Registry::get('virtual')->basic_offerings({loaded_revision => 1});
my @symbols = $offerings->query({contract_category => 'multiplier'}, ['underlying_symbol']);

subtest 'commission for underlying' => sub {
    my %expected_comm = (
        '1HZ10V'  => [100, 3.56144869308907e-05],
        R_10      => [100, 5.0366490434625e-05],
        R_25      => [50,  0.000125916226086562],
        R_50      => [20,  0.000251832452173125],
        R_75      => [15,  0.000377748678259687],
        R_100     => [10,  0.000503664904346249],
        '1HZ100V' => [10,  0.000356144869308907],
    );
    my $args = {
        bet_type => 'multup',
        stake    => 100,
        currency => 'USD',
    };

    foreach my $symbol (@symbols) {
        $args->{underlying} = $symbol;
        $args->{multiplier} = $expected_comm{$symbol}->[0];
        my $c = produce_contract($args);
        is $c->commission + 0, $expected_comm{$symbol}->[1] + 0, "commission for $symbol is $expected_comm{$symbol}->[1]";
    }
};

done_testing();
