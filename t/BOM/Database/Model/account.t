use strict;
use warnings;
use Test::More (tests => 9);
use Test::Warnings;
use Test::Exception;
use Test::Warn;
use BOM::Database::Model::Account;
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
'expecting to load the required account models for transfer';

lives_ok {
    $account = BOM::Database::Model::Account->new({
        'data_object_params' => {'account_id' => $account_id},
        db                   => $connection_builder->db
    });
    $account->load({'load_params' => {speculative => 1}});
}
'expect to load the account even with account_id instead of id';

cmp_ok($account->client_loginid, 'eq', $client->loginid, 'Check if it load the account properly');
cmp_ok($account->currency_code,  'eq', 'USD',            'Check if it load the account properly');

lives_ok {
    $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MX',
    });
    $account = BOM::Database::Model::Account->new({
            'data_object_params' => {
                'client_loginid' => $client->loginid,
                'currency_code'  => 'GBP'
            },
            db => $connection_builder->db
        });
    $account->save();
}
'expect to save the account';

isa_ok($account->class_orm_record, 'BOM::Database::AutoGenerated::Rose::Account');

$account->data_object_params->{'id'} = '11111';
cmp_ok($account->_extract_related_attributes_for_account_class_hashref({'data_object_params' => {'id' => '11111'}})->{'id'},
    'eq', '11111', 'Check if it can parse the id properly');
$account->data_object_params->{'account_id'} = '22222';
cmp_ok($account->_extract_related_attributes_for_account_class_hashref({'data_object_params' => {'account_id' => '22222'}})->{'id'},
    'eq', '22222', 'Check if it can parse the id properly');

$account->data_object_params(undef);
$account->_extract_related_attributes_for_account_class_hashref;
