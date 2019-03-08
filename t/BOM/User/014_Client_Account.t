use strict;
use warnings;

use Test::More tests => 10;
use Test::Exception;
use Test::Deep;
use Test::Warn;
use Date::Utility;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client qw( create_client );

use BOM::User::Client;
use BOM::User::Client::Account;

my $client = create_client();

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

ok(
    my $new_payment = $account_existing->add_payment({
            amount               => 100,
            payment_gateway_code => 'account_transfer',
            payment_type_code    => 'internal_transfer',
            status               => 'OK',
            staff_loginid        => 1,
            remark               => 'test Payment'
        }
    ),
    'Add payment'
);

#create a transaction because it will fire a trigger to set balance on Account.
my ($txn) = $new_payment->add_transaction({
    account_id    => $account_existing->id,
    amount        => 100,
    staff_loginid => 1,
    referrer_type => 'payment',
    action_type   => 'deposit',
    quantity      => 1,
    source        => 1,
});
$new_payment->save(cascade => 1);

#Reload the Account again as the balance should have been set by the db trigger and the current version of the object wont be aware of it.
my $account_with_payment = BOM::User::Client::Account->new(
    db             => $client->db,
    client_loginid => $client->loginid
);

cmp_ok($account_with_payment->balance, '==', 100, 'Balance set on account');

subtest 'total_withdrawals' => sub {
    my $client_two = create_client();
    my $account    = BOM::User::Client::Account->new(
        db             => $client->db,
        client_loginid => $client_two->loginid,
        currency_code  => 'USD'
    );

    is($account->total_withdrawals(), 0, "No payments have been made");

    ok(
        $account->add_payment({
                amount               => -100,
                payment_gateway_code => 'account_transfer',
                payment_type_code    => 'internal_transfer',
                status               => 'OK',
                staff_loginid        => 1,
                remark               => 'test Payment',
                payment_time         => '2017-01-01 00:00:00'
            }
        ),
        'Add payment'
    );
    ok(
        $account->add_payment({
                amount               => -100,
                payment_gateway_code => 'account_transfer',
                payment_type_code    => 'internal_transfer',
                status               => 'OK',
                staff_loginid        => 1,
                remark               => 'test Payment'
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
    ok(
        my $new_payment = $account->add_payment({
                amount               => 100,
                payment_gateway_code => 'account_transfer',
                payment_type_code    => 'internal_transfer',
                status               => 'OK',
                staff_loginid        => 1,
                remark               => 'test Payment'
            }
        ),
        'Add payment'
    );

#create a transaction because it will fire a trigger to set balance on Account.
    my ($txn) = $new_payment->add_transaction({
        account_id    => $account->id,
        amount        => 100,
        staff_loginid => 1,
        referrer_type => 'payment',
        action_type   => 'deposit',
        quantity      => 1,
        source        => 1,
    });
    $new_payment->save(cascade => 1);
    my $trx = $account->find_transaction(
        query => [
            id            => $txn->id,
            referrer_type => 'payment'
        ])->[0];
    is($trx->amount * 1, 100, 'Returned the correct transaction');
    my $testPayment = $trx->payment;
    is($testPayment->amount, 100, 'Test getting Payment from Transaction OK');
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
done_testing();
