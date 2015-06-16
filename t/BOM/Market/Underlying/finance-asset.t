#!/usr/bin/perl
use strict;
use warnings;

# This test script checks that our underlying supports the attributes
# formerly defined in Finance::Asset

use Test::More;
use BOM::Market::Underlying;

my $forex_symbol = 'frxAUDUSD';
my $forex        = new_ok('BOM::Market::Underlying' => [$forex_symbol]);
my $forex_2      = new_ok('BOM::Market::Underlying' => ['frxUSDJPY']);

subtest pip_size => sub {
    cmp_ok $forex->pip_size, '==', 0.00001, 'pip_size';
};

subtest market_convention => sub {
    is $forex->market_convention->{atm_setting}, 'atm_delta_neutral_straddle', 'market_convention->atm_setting';
};

subtest divisor => sub {
    is $forex->divisor, 1, 'divisor';
};

subtest display_name => sub {
    is $forex->display_name, 'AUD/USD', 'display_name';
};

subtest exchange_name => sub {
    is $forex->exchange_name, 'FOREX', 'exchange_name';
};

subtest market => sub {
    is $forex->market->name, 'forex', 'market->name';
};

done_testing();

