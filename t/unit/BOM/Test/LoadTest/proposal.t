use strict;
use warnings;
use Test::More;
use Test::MockObject;
use Test::MockModule;
use Test::MockTime qw(set_fixed_time);
use BOM::Test::LoadTest::Proposal;

subtest 'test get_params' => sub {
    # reset rand seed to fix rand sequence
    srand(1);
    my $tester                      = BOM::Test::LoadTest::Proposal->new();
    my $contract_for_cryBTCUSD_call = Test::MockObject->new();
    $contract_for_cryBTCUSD_call->set_always('market', 'cryptocurrency')->set_always('contract_type', 'MULTUP')
        ->set_always('data', {multiplier_range => [10, 20, 30, 40, 50]})->set_always('underlying_symbol', 'cryBTCUSD');
    $tester->set_contracts_for({'cryBTCUSD' => {'MULTUP' => $contract_for_cryBTCUSD_call}});

    ok(!$tester->get_params('BAD_TYPE', 'BAD_SYMBOL'), 'will return undef if no contracts for such type and symbol');
    is_deeply(
        $tester->get_params('MULTUP', 'cryBTCUSD'),
        {
            'duration_unit' => 's',
            'basis'         => 'stake',
            'contract_type' => 'MULTUP',
            'product_type'  => 'basic',
            'multiplier'    => 30,
            'symbol'        => 'cryBTCUSD',
            'amount'        => 9,
            'currency'      => 'USD'
        },
        'get crypto currency contract params'
    );

    my $contract_for_forex_call = Test::MockObject->new();
    $contract_for_forex_call->set_always('market', 'forex')->set_always('submarket', 'minor_pairs')->set_always('min_contract_duration', '1t')
        ->set_always('max_contract_duration', '5t');
    my $mocked_test = Test::MockModule->new('BOM::Test::LoadTest::Proposal');
    $mocked_test->mock('forex_duration_adjustments', sub { return (0, 0) });
    $tester->set_contracts_for({frxAUDCAD => {CALL => $contract_for_forex_call}});
    ok(!$tester->get_params('CALL', 'frxAUDCAD'), 'will return undef if forex_duration_adjustments return 0');
    undef $mocked_test;

    set_fixed_time(1661100000);
    is_deeply(
        $tester->get_params('CALL', 'frxAUDCAD'),
        {
            'duration_unit' => 't',
            'duration'      => 4,
            'amount'        => 10,
            'basis'         => 'stake',
            'date_start'    => time() + 1000,
            'contract_type' => 'CALL',
            'symbol'        => 'frxAUDCAD',
            'currency'      => 'USD'
        },
        "forex common CALL"
    );

    set_fixed_time(1661209000);    # current time is 22:00
    $contract_for_forex_call->set_always('market', 'forex')->set_always('min_contract_duration', '1d')->set_always('max_contract_duration', '365d');
    use Data::Dumper;
    is_deeply(
        $tester->get_params('CALL', 'frxAUDCAD'),
        {
            'contract_type' => 'CALL',
            'amount'        => 10,
            'basis'         => 'stake',
            'currency'      => 'USD',
            'duration'      => 1,
            'duration_unit' => 'd',
            'date_start'    => time() + 3 * 3600,
            'symbol'        => 'frxAUDCAD'
        },
        "forex common CALL in 22:00 oclock"
    );

};
done_testing();
