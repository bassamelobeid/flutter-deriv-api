#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::FailWarnings;

use Try::Tiny;
use BOM::Product::ContractFactory qw(produce_contract);

my $offerings = LandingCompany::Registry::get('svg')->basic_offerings({current_revision => 1});
my @symbols = $offerings->query({contract_category => 'multiplier'}, ['underlying_symbol']);

subtest 'multiplier range' => sub {
    my %expected = (
        '1HZ10V'  => 1,
        R_10      => 1,
        R_25      => 1,
        R_50      => 1,
        R_75      => 0,
        R_100     => 1,
        '1HZ100V' => 1,
    );
    my $args = {
        bet_type   => 'multup',
        stake      => 100,
        currency   => 'usd',
        multiplier => 100,
    };

    foreach my $symbol (@symbols) {
        $args->{underlying} = $symbol;
        my $c = produce_contract($args);
        if ($expected{$symbol}) {
            ok !$c->_validate_multiplier_range();
        } else {
            my $error = $c->_validate_multiplier_range();
            is $error->{message}, 'multiplier out of range';
            is $error->{message_to_client}->[0], 'Multiplier is not in acceptable range. Accepts [_1].', $symbol;
            is $error->{message_to_client}->[1], '15,30,50,75,150';
        }
    }
};

done_testing();
