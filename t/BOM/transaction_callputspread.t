#!/usr/bin/perl

use strict;
use warnings;

use Test::MockModule;
use Test::More;
use Test::FailWarnings;
use Test::Exception;

use Crypt::NamedKeys;
use Date::Utility;
use BOM::Transaction;
use BOM::Transaction::Validation;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Helper::Client qw(create_client top_up);

initialize_realtime_ticks_db();

Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';
my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');
$mock_validation->mock(validate_tnc => sub { note "mocked Transaction::Validation->validate_tnc returning nothing"; undef });

my $now = Date::Utility->new;
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'USD',
        recorded_date => $now
    });

my $tick_r100 = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch,
    underlying => 'R_100',
    quote      => 100,
});

my $cl = create_client('CR');
top_up $cl, 'USD', 5000;

subtest 'buy CALLSPREAD' => sub {
    my $contract = produce_contract({
        underlying   => 'R_100',
        bet_type     => 'CALLSPREAD',
        currency     => 'USD',
        payout       => 100,
        duration     => '2m',
        current_tick => $tick_r100,
        high_barrier => 'S10P',
        low_barrier  => 'S-10P',
    });

    my $error = do {
        my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
        $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

        my $mock_transaction = Test::MockModule->new('BOM::Transaction');
        my $mock_validation  = Test::MockModule->new('BOM::Transaction::Validation');
        # _validate_trade_pricing_adjustment() is tested in trade_validation.t
        $mock_validation->mock(_validate_trade_pricing_adjustment =>
                sub { note "mocked Transaction::Validation->_validate_trade_pricing_adjustment returning nothing"; () });
        $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 50,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $contract->date_start,
        });
        $txn->buy;
    };
    ok !$error;
};

subtest 'buy PUTSPREAD' => sub {
    my $contract = produce_contract({
        underlying   => 'R_100',
        bet_type     => 'PUTSPREAD',
        currency     => 'USD',
        payout       => 100,
        duration     => '2m',
        current_tick => $tick_r100,
        high_barrier => 'S10P',
        low_barrier  => 'S-10P',
    });

    my $error = do {
        my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
        $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

        my $mock_transaction = Test::MockModule->new('BOM::Transaction');
        my $mock_validation  = Test::MockModule->new('BOM::Transaction::Validation');
        # _validate_trade_pricing_adjustment() is tested in trade_validation.t
        $mock_validation->mock(_validate_trade_pricing_adjustment =>
                sub { note "mocked Transaction::Validation->_validate_trade_pricing_adjustment returning nothing"; () });
        $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 50,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $contract->date_start,
        });
        $txn->buy;
    };
    ok !$error;
};
