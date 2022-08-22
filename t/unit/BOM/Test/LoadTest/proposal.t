use strict;
use warnings;
use Test::More;
use Test::MockObject;
use BOM::Test::LoadTest::Proposal;

subtest 'test get_params' => sub {
    # reset rand seed to fix rand sequence
    srand(1);
    my $tester = BOM::Test::LoadTest::Proposal->new();
    my $contract_for_crycur_call = Test::MockObject->new();
    $contract_for_crycur_call->set_always('market', 'cryptocurrency')
        ->set_always('contract_type','CALL')
        ->set_always('data', {multiplier_range => [10,20,30,40,50]})
        ->set_always('underlying_symbol', 'crycur');
    $tester->set_contracts_for({
        'crycur' => {'CALL' => $contract_for_crycur_call} 
    });

    ok(!$tester->get_params('BAD_TYPE', 'BAD_SYMBOL'), 'will return undef if no contracts for such type and symbol');
    use Data::Dumper;
    is_deeply($tester->get_params('CALL','crycur'), 
    {
          'duration_unit' => 's',
          'basis' => 'stake',
          'contract_type' => 'CALL',
          'product_type' => 'basic',
          'multiplier' => 30,
          'symbol' => 'crycur',
          'amount' => 9,
          'currency' => 'USD'
        },
        'get crypto currency contract params'
    );
};
done_testing();