use strict;
use warnings;

use Test::More (tests => 5);
use Test::FailWarnings;
use Test::Exception;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use BOM::Market::Data::Tick;
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date => Date::Utility->new,
    }) for qw/frxUSDJPY R_100/;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for (qw/JPY USD/);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol => 'R_100',
        date   => Date::Utility->new
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => 'JPY',
        rates  => {
            1   => 0.2,
            2   => 0.15,
            7   => 0.18,
            32  => 0.25,
            62  => 0.2,
            92  => 0.18,
            186 => 0.1,
            365 => 0.13,
        },
        date         => Date::Utility->new,
        type         => 'implied',
        implied_from => 'USD'
    });

use BOM::Product::ContractFactory qw( produce_contract make_similar_contract simple_contract_info );

subtest 'produce_contract' => sub {
    plan tests => 3;

    my $contract_params = {
        bet_type   => 'FLASHD',
        duration   => '4t',
        underlying => 'frxUSDJPY',
        payout     => 1,
        currency   => 'USD',
        barrier    => 108.26,
    };
    my $contract;
    lives_ok {
        $contract = produce_contract($contract_params);
    }
    'produce a contract';

    isa_ok($contract, 'BOM::Product::Contract');

    note "You don't really want to reuse these hash-refs, the factory will change them.";
    delete $contract_params->{bet_type};
    throws_ok { $contract = produce_contract($contract_params) } qr/bet_type.*required/, 'Improper construction arguments bubble up.';

};

subtest 'make_similar_contract' => sub {
    plan tests => 6;

    my $contract_params = {
        bet_type     => 'CALL',
        duration     => '4d',
        underlying   => 'frxUSDJPY',
        payout       => 1,
        currency     => 'USD',
        barrier      => 108.26,
        current_spot => 100,
    };
    my $contract = produce_contract($contract_params);
    my $similar;
    note "THIS is what you should do if you're considering reusing a hashref.";
    lives_ok {
        $similar = make_similar_contract($contract, {barrier => 'S0P'});
    }
    'make similar contract appears to work';

    isa_ok($similar, 'BOM::Product::Contract');
    is($similar->barrier->as_relative, 'S0P', 'new contract has the proper barrier');
    isnt($contract->barrier->as_relative, 'S0P', '... and the old one did not');
    ok($similar->date_expiry->is_same_as($contract->date_expiry),
        '.. but they both end at the same time.. which we will take to mean they are otherwise the same.');

    lives_ok {
        $similar = make_similar_contract($contract, {priced_at => 'now'});
    }
    'make similar contract changing pricing date appears to work';
};

subtest 'simple_contract_info' => sub {
    plan tests => 9;

    my $contract_params = {
        bet_type   => 'DOUBLEUP',
        duration   => '4d',
        underlying => 'frxUSDJPY',
        payout     => 1,
        currency   => 'USD',
        barrier    => 108.26,
    };

    my ($desc, $ticky, $spready) = simple_contract_info($contract_params);

    like $desc, qr#^Win payout if#, 'our params got us what seems like it might be a description';
    ok(!$ticky,   "our params do not create a tick expiry contract.");
    ok(!$spready, "our params do not create a spread contract.");

    $contract_params = {
        bet_type   => 'FLASHD',
        duration   => '4t',
        underlying => 'frxUSDJPY',
        payout     => 1,
        currency   => 'USD',
        barrier    => 108.26,
    };

    ($desc, $ticky, $spready) = simple_contract_info($contract_params);

    like $desc, qr#^Win payout if#, 'our params got us what seems like it might be a description';
    ok($ticky,    "our params create a tick expiry contract.");
    ok(!$spready, "our params do not create a spread contract.");

    $contract_params = {
        bet_type         => 'SPREADU',
        underlying       => 'R_100',
        date_start       => 1449810000,    # 2015-12-11 05:00:00
        amount_per_point => 1,
        stop_loss        => 10,
        stop_profit      => 10,
        currency         => 'USD',
        stop_type        => 'point',
    };

    ($desc, $ticky, $spready) = simple_contract_info($contract_params);

    like $desc, qr#^USD 1.00#, 'our params got us what seems like it might be a description';
    ok(!$ticky,  "our params do not create a tick expiry contract.");
    ok($spready, "our params create a spread contract.");
};

subtest 'invalid contracts does not die' => sub {
    my $invalid_shortcode = 'RUNBET_DOUBLEUP_GBP20_R_50_5';
    lives_ok {
        my $contract = produce_contract($invalid_shortcode, 'GBP');
        isa_ok $contract, 'BOM::Product::Contract::Invalid';
    } 'produce_contract on legacy shortcode lives';

    lives_ok {
        my @info = simple_contract_info($invalid_shortcode, 'GBP');
        like($info[0], qr/Legacy contract. No further information is available/, 'legacy longcode');
    } 'simple_contract_info for legacy shortcode lives';
};

subtest 'unknown shortcode does not die' => sub {
    my $unknown = 'INTRADD_FRXUSDJPY_20_12_JAN_07_4_6';
    lives_ok {
        my $contract = produce_contract($unknown, 'GBP');
        isa_ok $contract, 'BOM::Product::Contract::Invalid';
    } 'unknown shortcode';
};

1;
