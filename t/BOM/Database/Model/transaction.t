use strict;

use Test::More tests => 11;

use DBI;
use DBD::SQLite;
use Test::Exception;
use BOM::Database::Model::Account;
use BOM::Database::Model::Transaction;
use BOM::Database::Model::Constants;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $connection_builder;
my $client;
my $account;
my $account_id;

lives_ok {
    $connection_builder = BOM::Database::ClientDB->new({
        broker_code => 'CR',
    });

    $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    $account    = $client->set_default_account('USD');
    $account_id = $account->id;
}
'expecting to create the required account models for transfer';

my $transaction;
my $transaction_id;
my $payment;

lives_ok {
    $transaction = $client->payment_legacy_payment(
        amount       => 3,
        currency     => 'USD',
        payment_type => 'adjustment',
        remark       => 'Comment field',
    );
    $transaction_id = $transaction->id;
    $payment        = $transaction->payment;
}
'expect to load the account even with account_id instead of id';

lives_ok {
    $transaction = BOM::Database::Model::Transaction->new({
        data_object_params => {'transaction_id' => $transaction_id},
        db                 => $connection_builder->db
    });
    $transaction->load();
}
'expect to save the account';

cmp_ok($transaction->transaction_record->account_id,    'eq', $account_id, 'Check if it load the transaction properly account id');
cmp_ok($transaction->transaction_record->amount,        '==', 3,           'Check if it load the account properly amount');
cmp_ok($transaction->transaction_record->referrer_type, 'eq', 'payment',   'Check if it load the account properly referrer_type');
cmp_ok(
    $transaction->transaction_record->action_type,
    'eq',
    $BOM::Database::Model::Constants::DEPOSIT,
    'Check if it load the account properly action_type'
);
cmp_ok($transaction->transaction_record->payment_id,    '==', $payment->id, 'Check if it load the account properly payment_id');
cmp_ok($transaction->transaction_record->staff_loginid, 'eq', 'system',     'Check if it load the account properly staff_loginid');
# note.. we used to test transaction-remark here, but we never writes that for payments,
# so the new payment handlers don't write it.
cmp_ok($transaction->transaction_record->payment->remark, 'eq', 'Comment field', 'Check if it load the account properly remark');

isa_ok($transaction->class_orm_record, 'BOM::Database::AutoGenerated::Rose::Transaction');

