#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 5;
use Test::Exception;
use Test::Warnings;

use BOM::User::Client;

use BOM::Database::AutoGenerated::Rose::Transaction::Manager;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Database::Helper::FinancialMarketBet;

my $client;
my $account;
my $fmb;
my $fmb2;
my $expired_fmb;
my $account_data;

subtest 'Init' => sub {
    lives_ok {
        $client       = BOM::User::Client->new({loginid => 'CR2002'});
        $account      = $client->default_account;
        $account_data = {
            client_loginid => $client->loginid,
            currency_code  => 'USD',
        };

        $client->payment_legacy_payment(
            currency         => 'USD',
            amount           => 500,
            remark           => 'here is money',
            payment_type     => 'credit_debit_card',
            transaction_time => Date::Utility->new->datetime_yyyymmdd_hhmmss,
        );

        $fmb = BOM::Test::Data::Utility::UnitTestDatabase::create_fmb({
            type       => 'fmb_higher_lower',
            account_id => $account->id,
        });
        $fmb2 = BOM::Test::Data::Utility::UnitTestDatabase::create_fmb({
            type             => 'fmb_higher_lower',
            account_id       => $account->id,
            transaction_time => '2010-12-02 12:00:00'
        });
        $expired_fmb = BOM::Test::Data::Utility::UnitTestDatabase::create_fmb({
            type            => 'fmb_higher_lower',
            account_id      => $account->id,
            start_time      => '2011-09-02 12:00:00',
            expiry_time     => '2011-09-02 12:05:00',
            settlement_time => '2011-09-02 12:05:00'
        });
    }
    'Added required fixtures successfully';
};

my $db = $account->db;
subtest 'buy and sell without setting transaction time' => sub {
    my $fmb_helper;

    my $txn_id;
    lives_ok {
        $fmb_helper = BOM::Database::Helper::FinancialMarketBet->new({
            account_data => $account_data,
            bet          => $fmb,
            db           => $account->db,
        });
        $fmb_helper->bet_data->{quantity} = 1;
        $txn_id = $fmb_helper->buy_bet;
    }
    'Buy fmb successfully';

    my $trxn = BOM::Database::AutoGenerated::Rose::Transaction::Manager->get_transaction(
        query => [
            financial_market_bet_id => $fmb->id,
            action_type             => 'buy'
        ],
        db => $db,
    )->[0];
    is $txn_id, $trxn->id, "buy_bet returned correct transaction id";
    cmp_ok($fmb->purchase_time, 'ne', $trxn->transaction_time, 'Not equal time for purchase_time and transaction_time');

    lives_ok {
        $fmb_helper->bet_data->{sell_price} = $fmb->payout_price;
        $txn_id = $fmb_helper->sell_bet;
    }
    'bet sold';
    isnt $txn_id, undef, 'successfully sold';

    $trxn = BOM::Database::AutoGenerated::Rose::Transaction::Manager->get_transaction(
        query => [
            financial_market_bet_id => $fmb->id,
            action_type             => 'sell'
        ],
        db => $db,
    )->[0];
    is $txn_id, $trxn->id, "sell_bet returned correct transaction id";
};

subtest 'sell open expired bet' => sub {
    $expired_fmb->sell_price($expired_fmb->payout_price);
    my $fmb_helper = BOM::Database::Helper::FinancialMarketBet->new({
        account_data => $account_data,
        bet          => $expired_fmb,
        db           => $account->db,
    });
    $fmb_helper->bet_data->{quantity} = 1;
    isnt($fmb_helper->sell_bet, undef, 'Sell expired fmb successfully');
};

subtest 'buy and sell by setting transaction time' => sub {
    my $fmb_helper;

    my $txn_id;
    lives_ok {
        $fmb_helper = BOM::Database::Helper::FinancialMarketBet->new({
            account_data => $account_data,
            bet          => $fmb2,
            db           => $account->db,
        });
        $fmb_helper->bet_data->{quantity} = 1;
        $txn_id = $fmb_helper->buy_bet;
    }
    'Buy fmb and set transaction time successfully';

    my $trxn = BOM::Database::AutoGenerated::Rose::Transaction::Manager->get_transaction(
        query => [
            financial_market_bet_id => $fmb2->id,
            action_type             => 'buy'
        ],
        db => $db,
    )->[0];
    is $txn_id, $trxn->id, "buy_bet returned correct transaction id";

    cmp_ok($fmb2->purchase_time, 'eq', $trxn->transaction_time, 'transaction_time set successfully');

    $fmb2->sell_price(0);
    $txn_id = $fmb_helper->sell_bet;
    isnt $txn_id, undef, 'Sell fmb2 successfully';

    $trxn = BOM::Database::AutoGenerated::Rose::Transaction::Manager->get_transaction(
        query => [
            financial_market_bet_id => $fmb2->id,
            action_type             => 'sell'
        ],
        db => $db,
    )->[0];
    is $txn_id, $trxn->id, "sell_bet returned correct transaction id";
};
