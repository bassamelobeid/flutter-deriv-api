#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;
use List::Util qw(all);
use BOM::Product::ContractFinder;

subtest 'contract finder basic' => sub {
    my $contracts                        = BOM::Product::ContractFinder->new->basic_contracts_for({symbol => 'frxUSDJPY'});
    my %expected_forward_starting_params = (
        contract_category => 'callput',
        expiry_type       => 'intraday',
        start_type        => 'forward'
    );

    foreach my $data (@{$contracts->{available}}) {
        if (all { $data->{$_} eq $expected_forward_starting_params{$_} } qw(contract_category expiry_type start_type)) {
            ok exists $data->{forward_starting_options}, "forward starting options available for $data->{expiry_type} and $data->{contract_category}";
        } else {
            ok !exists $data->{forward_starting_options},
                "forward starting options not available for $data->{expiry_type} and $data->{contract_category}";
        }
    }
};

done_testing();
