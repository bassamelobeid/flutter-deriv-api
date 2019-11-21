#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;

use BOM::Product::ContractFactory qw(produce_contract);
use LandingCompany::Registry;
use Try::Tiny;

my $offerings = LandingCompany::Registry::get('svg')->basic_offerings({current_revision => 1});
my @symbols = $offerings->query({contract_category => 'multiplier'}, ['underlying_symbol']);

subtest 'commission for underlying' => sub {
    my %expected_comm = (
        '1HZ10V'  => [100, 0.00005],
        R_10      => [100, 0.00005],
        R_25      => [50,  0.000126],
        R_50      => [20,  0.000252],
        R_75      => [15,  0.000378],
        R_100     => [10,  0.000504],
        '1HZ100V' => [10,  0.000504],
    );
    my $args = {
        bet_type => 'multup',
        stake    => 100,
        currency => 'usd',
    };

    foreach my $symbol (@symbols) {
        $args->{underlying} = $symbol;
        $args->{multiplier} = $expected_comm{$symbol}->[0];
        my $c = produce_contract($args);
        is $c->commission + 0, $expected_comm{$symbol}->[1] + 0, "commission for $symbol is $expected_comm{$symbol}->[1]";
    }
};

done_testing();
