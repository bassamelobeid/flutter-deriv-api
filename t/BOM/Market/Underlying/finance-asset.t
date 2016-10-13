#!/etc/rmg/bin/perl
use strict;
use warnings;

# This test script checks that our underlying supports the attributes
# formerly defined in Finance::Asset

use Test::More;
use BOM::MarketData qw(create_underlying);

my $forex_symbol = 'frxAUDUSD';
my $forex        = new_ok('Quant::Framework::Underlying' => [$forex_symbol]);
my $forex_2      = new_ok('Quant::Framework::Underlying' => ['frxUSDJPY']);

subtest pip_size => sub {
    cmp_ok $forex->pip_size, '==', 0.00001, 'pip_size';
};

subtest market_convention => sub {
    is $forex->market_convention->{atm_setting}, 'atm_delta_neutral_straddle', 'market_convention->atm_setting';
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

