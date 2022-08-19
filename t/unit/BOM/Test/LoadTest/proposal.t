#!/usr/bin/env perl

use BOM::Test::LoadTest::Proposal;

my $app_id      = 16303;
my $end_point   = 'ws://127.0.0.1:5004';
my $load_tester = BOM::Test::LoadTest::Proposal->new(
    end_point => $end_point,
    app_id    => $app_id,
);
use Data::Dumper;
print Dumper([$load_tester->all_markets]);

__END__
$VAR1 = [
          'basket_index',
          'commodities',
          'cryptocurrency',
          'forex',
          'indices',
          'synthetic_index'
        ];
/home/git/regentmarkets/bom-test/bin/proposal_sub.pl -s 10 -a 16303 -c 5 -r 120 -m synthetic_index,forex

/home/git/regentmarkets/bom-test/bin/proposal_sub.pl -s 10 -a 16303 -c 5 -r 120 -m commodities
good: basket_index
commodities
indices
synthetic_index
forex
bad: cryptocurrency
