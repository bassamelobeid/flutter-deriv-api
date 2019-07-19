use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::Deep;
use Test::Warn;
use Date::Utility;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client qw( create_client top_up );

use BOM::User::Client;
use BOM::User::Client::Account;

plan tests => 5;

subtest 'Account payment' => sub {
    my $client  = create_client();
    my $account = new_ok(
        "BOM::User::Client::Account" => [
            db             => $client->db,
            client_loginid => $client->loginid,
            currency_code  => 'USD'
        ]);

    cmp_ok($account->id, '>', 0, 'Account id set from database insert');

    my $account_existing = new_ok(
        "BOM::User::Client::Account" => [
            db             => $client->db,
            client_loginid => $client->loginid
        ]);

    is($account_existing->currency_code(), 'USD', 'Existing account fetched from DB');

    #create a transaction because it will fire a trigger to set balance on Account.
    my $params = {
        amount               => 100,
        payment_gateway_code => 'account_transfer',
        payment_type_code    => 'internal_transfer',
        status               => 'OK',
        staff_loginid        => 1,
        remark               => 'test Payment',
        account_id           => $account_existing->id,
        source               => 1,
    };

    ok(my $txn = $account_existing->add_payment_transaction($params), 'Add payment');

    verify_txn($txn, $params, 0);

    #Reload the Account again as the balance should have been set by the db trigger and the current version of the object wont be aware of it.
    my $account_with_payment = BOM::User::Client::Account->new(
        db             => $client->db,
        client_loginid => $client->loginid
    );

    cmp_ok($account_with_payment->balance, '==', 100, 'Balance set on account');
};

subtest 'total_withdrawals' => sub {
    my $client_two = create_client();
    my $account    = BOM::User::Client::Account->new(
        db             => $client_two->db,
        client_loginid => $client_two->loginid,
        currency_code  => 'USD'
    );

    top_up $client_two, 'USD', 200;

    is($account->total_withdrawals(), 0, "No payments have been made");

    ok(
        $account->add_payment_transaction({
                amount               => -100,
                payment_gateway_code => 'account_transfer',
                payment_type_code    => 'internal_transfer',
                status               => 'OK',
                staff_loginid        => 1,
                remark               => 'test Payment',
                payment_time         => '2017-01-01 00:00:00',
                account_id           => $account->id,
                source               => 1,
            }
        ),
        'Add payment'
    );
    ok(
        $account->add_payment_transaction({
                amount               => -100,
                payment_gateway_code => 'account_transfer',
                payment_type_code    => 'internal_transfer',
                status               => 'OK',
                staff_loginid        => 1,
                remark               => 'test Payment',
                account_id           => $account->id,
                source               => 1,
            }
        ),
        'Add payment'
    );

    is($account->total_withdrawals() * 1,                                          200, "200 in  payments have been made");
    is($account->total_withdrawals(Date::Utility->new('2018-01-01 00:00:00')) * 1, 100, '100 in payments since 01 jan 2018');

};

subtest find_transaction => sub {
    my $client  = create_client();
    my $account = BOM::User::Client::Account->new(
        db             => $client->db,
        client_loginid => $client->loginid,
        currency_code  => 'USD'
    );
#create a transaction because it will fire a trigger to set balance on Account.
    ok(
        my $txn = $account->add_payment_transaction({
                amount               => 100,
                payment_gateway_code => 'account_transfer',
                payment_type_code    => 'internal_transfer',
                status               => 'OK',
                staff_loginid        => 1,
                remark               => 'test Payment',
                account_id           => $account->id,
                source               => 1,
            }
        ),
        'Add payment'
    );

    my $trx = $account->find_transaction(
        query => [
            id            => $txn->id,
            referrer_type => 'payment'
        ])->[0];
    is($trx->amount + 0, 100, 'Returned the correct transaction');
    my $testPayment = $trx->payment;
    is($testPayment->amount + 0, 100, 'Test getting Payment from Transaction OK');
};

subtest default_account => sub {

    my $client = create_client();

    $client->db->dbic->run(
        fixup => sub {
            my $sth = $_->prepare("INSERT INTO transaction.account (client_loginid, currency_code, is_default) VALUES (?,?,?)");
            $sth->execute($client->loginid, 'AUD', 'FALSE');
        });

    my $account1 = BOM::User::Client::Account->new(
        db             => $client->db,
        client_loginid => $client->loginid,
        currency_code  => 'USD'
    );

    $client->db->dbic->run(
        fixup => sub {
            my $sth = $_->prepare("INSERT INTO transaction.account (client_loginid, currency_code, is_default) VALUES (?,?,?)");
            $sth->execute($client->loginid, 'GBP', 'FALSE');
        });
    is($client->account->currency_code(), 'USD', 'Correct account returned');
};

sub verify_txn {
    my ($txn, $call_params, $initial_balance) = @_;

    isa_ok $txn, 'BOM::User::Client::PaymentTransaction', 'Correct output type';
    my $trasaction_time = Date::Utility->new($txn->transaction_time);
    cmp_ok($trasaction_time->epoch(), '>=', time - 1, 'Acceptable transaction time');
    cmp_ok($trasaction_time->epoch(), '<=', time,     'Acceptable transaction time');
    map { $txn->{$_} += 0 } qw(amount balance_after);

    my $expected_txn = {
        'payment_id'              => $txn->payment_id,
        'source'                  => $call_params->{source},
        'balance_after'           => $initial_balance + $call_params->{amount},
        'referrer_type'           => 'payment',
        'quantity'                => 1,
        'action_type'             => 'deposit',
        'transaction_id'          => $txn->transaction_id,
        'id'                      => $txn->id,
        'remark'                  => $call_params->{remark},
        'staff_loginid'           => $call_params->{staff_loginid},
        'amount'                  => $call_params->{amount},
        'app_markup'              => undef,
        'financial_market_bet_id' => undef,
        'account_id'              => $call_params->{account_id},
        'transaction_time'        => $txn->transaction_time,
    };

    is_deeply $txn, $expected_txn, 'Correct output values';
}

done_testing();
