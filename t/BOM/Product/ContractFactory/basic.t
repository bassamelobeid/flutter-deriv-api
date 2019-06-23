use strict;
use warnings;

use Test::More;
use Test::Warnings qw/warning/;
use Test::Exception;
use Test::MockModule;
use File::Spec;
use Try::Tiny;
use JSON;

use Postgres::FeedDB::Spot::Tick;
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::Product::ContractFactory qw( produce_contract make_similar_contract );

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

subtest 'produce_contract' => sub {
    my $contract_params = {
        bet_type     => 'PUT',
        duration     => '4t',
        underlying   => 'frxUSDJPY',
        payout       => '1',
        currency     => 'USD',
        barrier      => 108.26,
        current_spot => 100,

    };
    my $contract;
    lives_ok {
        $contract = produce_contract($contract_params);
        isa_ok($contract, 'BOM::Product::Contract');
    }
    'produce a contract';

    is to_json([$contract->payout]), '[1]', 'payout is number';
};

subtest 'produce_contract exception' => sub {
    my $contract_params = {
        bet_type   => 'PUT',
        duration   => '4t',
        underlying => 'frxUSDJPY',
        payout     => 1,
        currency   => 'USD',
        barrier    => 108.26,
    };

    foreach my $undef (
        [{bet_type   => undef}, 'Missing required contract parameters ([_1]).'],
        [{duration   => undef}, 'Please specify either [_1] or [_2].'],
        [{underlying => undef}, 'Missing required contract parameters ([_1]).'],
        [{currency   => undef}, 'Missing required contract parameters ([_1]).'])
    {
        try {
            produce_contract({%$contract_params, %{$undef->[0]}});
        }
        catch {
            isa_ok $_, 'BOM::Product::Exception';
            my $missing = (keys %{$undef->[0]})[0];
            is $_->message_to_client->[0], $undef->[1];
        }
    }
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
    my $res;
    warning { $res = $similar->barrier->as_relative }, qr/No basis tick for/;
    is($res, 'S0P', 'new contract has the proper barrier');
    warning { $res = $contract->barrier->as_relative }, qr/No basis tick for/;
    isnt($res, 'S0P', '... and the old one did not');
    ok($similar->date_expiry->is_same_as($contract->date_expiry),
        '.. but they both end at the same time.. which we will take to mean they are otherwise the same.');

    lives_ok {
        $similar = make_similar_contract($contract, {priced_at => 'now'});
    }
    'make similar contract changing pricing date appears to work';
};

subtest 'unknown shortcode does not die' => sub {
    my $unknown = 'PUT_FRXUSDJPY_20_12_JAN_07_4_6';
    lives_ok {
        my $contract = produce_contract($unknown, 'GBP');
        isa_ok $contract, 'BOM::Product::Contract::Invalid';
    }
    'unknown shortcode';
};

done_testing();
