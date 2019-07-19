#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More qw(no_plan);
use Test::Exception;
use Test::Output qw(:functions);
use Test::Warn;
use Format::Util::Numbers qw(roundcommon);

use BOM::Database::DataMapper::Payment;
use BOM::Database::DataMapper::Account;

use FindBin;
use lib "$FindBin::Bin/../../lib";
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use ClientAccountTestHelper;

use lib qw(/home/git/regentmarkets/bom/cgi);

subtest 'client Balance' => sub {
    plan tests => 38;
    my $client = ClientAccountTestHelper::create_client({
        broker_code => 'CR',
    });
    my $account = $client->set_default_account('GBP');

    my $args = {
        currency => 'GBP',
        amount   => 1234.25,
        remark   => 'here is money',
        staff    => 'system'
    };
    my $payment_expected = {
        payment_gateway_code => 'free_gift',
        payment_type_code    => 'free_gift'
    };
    my $initial_balance = 0;
    my $txn             = $client->payment_free_gift(%$args);
    verify_txn($txn, $account, $args, $initial_balance, $payment_expected);

    $args->{amount}  = 1234.25;
    $initial_balance = 1234.25;
    $txn             = $client->payment_free_gift(%$args);
    verify_txn($txn, $account, $args, $initial_balance, $payment_expected);

    $args->{amount}  = -357.30;
    $initial_balance = 1234.25 + 1234.25;
    $txn             = $client->payment_free_gift(%$args);
    verify_txn($txn, $account, $args, $initial_balance, $payment_expected);

    $args->{amount}  = -1111.19;
    $initial_balance = 1234.25 + 1234.25 - 357.30;
    $txn             = $client->payment_free_gift(%$args);
    verify_txn($txn, $account, $args, $initial_balance, $payment_expected);

    #ClientAccountTestHelper::create_fmb({
    #    type       => 'fmb_higher_lower_sold_won',
    #    account_id => $account->id,
    #    sell_price => 565.23,
    #    buy_price  => 165.12
    #});

    my ($account_mapper, $payment_mapper, $payment_mapper_client, $aggregate_deposit, $aggregate_withdrawal, $aggregate_deposit_withdrawal,
        $withdrawal_ref);
    lives_ok {
        $account_mapper = BOM::Database::DataMapper::Account->new({
            client_loginid => $account->client_loginid,
            currency_code  => 'GBP',
        });
        $payment_mapper = BOM::Database::DataMapper::Payment->new({
            client_loginid => $account->client_loginid,
            currency_code  => 'GBP',
        });
        $payment_mapper_client = BOM::Database::DataMapper::Payment->new({
            client_loginid => $account->client_loginid,
        });
    }
    'Successfully get Balance related figure for client, GBP';

    $aggregate_deposit    = $payment_mapper->get_total_deposit();
    $aggregate_withdrawal = $payment_mapper->get_total_withdrawal();

    $aggregate_deposit_withdrawal = $aggregate_deposit - $aggregate_withdrawal;

    is($account_mapper->get_balance(), 1000.01,   'check account balance');
    is($aggregate_deposit,             '2468.50', 'check aggregate deposit');
    is($aggregate_withdrawal,          1468.49,   'check aggregate withdrawal');
    is($aggregate_deposit_withdrawal,  1000.01,   'check aggredate deposit & withdrawal');

    lives_ok {
        $account_mapper = BOM::Database::DataMapper::Account->new({
            client_loginid => 'MX0013',
            currency_code  => 'USD',
        });
        $payment_mapper = BOM::Database::DataMapper::Payment->new({
            client_loginid => 'MX0013',
            currency_code  => 'USD',
        });
        $payment_mapper_client = BOM::Database::DataMapper::Payment->new({
            client_loginid => 'MX0013',
        });
    }
    'Successfully get Balance related figure for MX0013, USD';

    $aggregate_deposit    = $payment_mapper->get_total_deposit();
    $aggregate_withdrawal = $payment_mapper->get_total_withdrawal();

    $aggregate_deposit_withdrawal = $aggregate_deposit - $aggregate_withdrawal;

    cmp_ok($account_mapper->get_balance(), '==', 4.96, 'check account balance');
    cmp_ok($aggregate_deposit,             '==', 20,   'check aggregate deposit');
    cmp_ok($aggregate_withdrawal,          '==', 0,    'no withdrawal has been made');
    cmp_ok($aggregate_deposit_withdrawal,  '==', 20,   'check aggredate deposit & withdrawal');

    lives_ok {
        $account_mapper = BOM::Database::DataMapper::Account->new({
            client_loginid => 'TEST9999',
            currency_code  => 'USD',
        });
        $payment_mapper = BOM::Database::DataMapper::Payment->new({
            client_loginid => 'TEST9999',
            currency_code  => 'USD',
        });
        $payment_mapper_client = BOM::Database::DataMapper::Payment->new({
            client_loginid => 'TEST9999',
        });
    }
    'Successfully get Balance related figure for TEST9999, USD';

    throws_ok { $aggregate_deposit = $payment_mapper->get_total_deposit(); } qr/No such domain with the broker code TEST/,
        'Get total deposit of unknown broker code failed';
    throws_ok { $aggregate_withdrawal = $payment_mapper->get_total_withdrawal(); } qr/No such domain with the broker code TEST/,
        'Get total withdrawal failed for unknow broker code failed';

    $aggregate_deposit_withdrawal = $aggregate_deposit - $aggregate_withdrawal;

    throws_ok { $account_mapper->get_balance(); } qr/No such domain with the broker code TEST/, 'check account balance for invalid broker code';
};

subtest 'payment transaction' => sub {
    my $client = ClientAccountTestHelper::create_client({
        broker_code => 'CR',
    });
    my $account = new_ok(
        "BOM::User::Client::Account" => [
            db             => $client->db,
            client_loginid => $client->loginid,
            currency_code  => 'USD'
        ]);

    cmp_ok($account->id, '>', 0, 'Account id set from database insert');

    my $amount = 15;
    my $fee    = 1.5;
    my $args   = {
        currency => 'USD',
        amount   => $amount,
        remark   => 'test remark',
        fees     => $fee,            # it is non-effective in this payment type
        source   => 500,
        staff    => 'test script',
    };

    my $payment_expected = {
        payment_gateway_code => 'legacy_payment',
        payment_type_code    => 'ewallet'
    };

    my $initial_balance = 0;
    my $txn = $client->payment_legacy_payment(%$args, payment_type => 'ewallet');
    verify_txn($txn, $account, {%$args, payment_type => 'ewallet'}, $initial_balance, $payment_expected);

    $payment_expected->{payment_type_code}    = 'free_gift';
    $payment_expected->{payment_gateway_code} = 'free_gift';
    $initial_balance                          = 15;
    $txn                                      = $client->payment_free_gift(%$args);
    verify_txn($txn, $account, $args, $initial_balance, $payment_expected);

    $payment_expected->{payment_type_code}    = 'mt5_transfer';
    $payment_expected->{payment_gateway_code} = 'account_transfer';
    $payment_expected->{transfer_fees}        = '1.5';
    $initial_balance                          = 30;
    $txn                                      = $client->payment_mt5_transfer(%$args);
    verify_txn($txn, $account, $args, $initial_balance, $payment_expected);

    delete $payment_expected->{transfer_fees};
    $payment_expected->{payment_type_code}    = 'payment_fee';
    $payment_expected->{payment_gateway_code} = 'payment_fee';
    $initial_balance                          = 45;
    $txn                                      = $client->payment_payment_fee(%$args);
    verify_txn($txn, $account, $args, $initial_balance, $payment_expected);

    $payment_expected->{payment_type_code}    = 'bank_money_transfer';
    $payment_expected->{payment_gateway_code} = 'bank_wire';
    $initial_balance                          = 60;
    $txn                                      = $client->payment_bank_wire(%$args);
    verify_txn($txn, $account, $args, $initial_balance, $payment_expected);

    $payment_expected->{payment_type_code}    = 'cash_transfer';
    $payment_expected->{payment_gateway_code} = 'western_union';
    $initial_balance                          = 75;
    $txn                                      = $client->payment_western_union(%$args);
    verify_txn($txn, $account, $args, $initial_balance, $payment_expected);

    $payment_expected->{payment_type_code}    = 'affiliate_reward';
    $payment_expected->{payment_gateway_code} = 'affiliate_reward';
    $initial_balance                          = 90;
    $txn                                      = $client->payment_affiliate_reward(%$args);
    verify_txn($txn, $account, $args, $initial_balance, $payment_expected);

    $payment_expected->{payment_type_code}    = 'arbitrary_markup';
    $payment_expected->{payment_gateway_code} = 'arbitrary_markup';
    $initial_balance                          = 105;
    $txn                                      = $client->payment_arbitrary_markup(%$args);
    verify_txn($txn, $account, $args, $initial_balance, $payment_expected);

    $payment_expected->{payment_type_code}    = 'external_cashier';
    $payment_expected->{payment_gateway_code} = 'doughflow';
    $initial_balance                          = 120;
    delete $args->{source};
    $txn = $client->payment_doughflow(%$args);
    isa_ok $txn, 'BOM::User::Client::PaymentTransaction::Doughflow', 'Correct class for doughflow payment transaction object';
    verify_txn($txn, $account, $args, $initial_balance, $payment_expected);
};

sub verify_txn {
    my ($txn, $account, $call_args, $initial_balance, $payment_expected) = @_;

    map { $txn->{$_} += 0 } qw(amount balance_after);

    isa_ok $txn, 'BOM::User::Client::PaymentTransaction', "Correct output type for $payment_expected->{payment_type_code}";
    my $trasaction_time = Date::Utility->new($txn->transaction_time);
    cmp_ok($trasaction_time->epoch(), '>=', time - 1, "Acceptable transaction time for $payment_expected->{payment_type_code}");
    cmp_ok($trasaction_time->epoch(), '<=', time,     "Acceptable transaction time for $payment_expected->{payment_type_code}");
    is(
        roundcommon('0.00001', $account->balance),
        roundcommon('0.00001', $initial_balance + $call_args->{amount}),
        "Balance is correct after transfer ($payment_expected->{payment_type_code})"
    );
    my $expected_txn = {
        'payment_id'              => $txn->payment_id,
        'source'                  => $call_args->{source},
        'balance_after'           => $account->balance + 0,
        'referrer_type'           => 'payment',
        'quantity'                => 1,
        'action_type'             => ($call_args->{amount} >= 0) ? 'deposit' : 'withdrawal',
        'transaction_id'          => $txn->transaction_id,
        'id'                      => $txn->id,
        'remark'                  => $call_args->{remark},
        'staff_loginid'           => $call_args->{staff},
        'amount'                  => $call_args->{amount},
        'app_markup'              => undef,
        'financial_market_bet_id' => undef,
        'account_id'              => $account->id,
        'transaction_time'        => $txn->transaction_time,
        (exists $txn->{fee_payment_id})
        ? (
            'fee_payment_id'     => $txn->fee_payment_id,
            'fee_transaction_id' => $txn->fee_transaction_id,
            )
        : ()};
    is_deeply $txn, $expected_txn, "Correct output values in $payment_expected->{payment_type_code}";

    verify_payment($account->db->dbic, $txn, $payment_expected);
}

sub verify_payment {
    my ($dbic, $txn, $payment_expected) = @_;

    my $payment = $dbic->run(
        fixup => sub {
            $_->selectrow_hashref(
                "Select pp.* FROM payment.payment pp JOIN transaction.transaction tt
                ON pp.id = tt.payment_id where tt.id = ?",
                undef,
                $txn->transaction_id,
            );
        });
    $payment_expected->{id} = $txn->payment_id;
    is_deeply { $payment->%{keys %$payment_expected} }, $payment_expected, "payment values are correct ($payment_expected->{payment_type_code})";
}

done_testing();
