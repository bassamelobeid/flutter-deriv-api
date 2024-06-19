use strict;
use warnings;
use Test::More (tests => 3);
use Test::Warnings;

use Test::Exception;
use BOM::Database::Model::Account;
use BOM::Database::DataMapper::AccountBase;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $base;

lives_ok {
    $base = BOM::Database::DataMapper::AccountBase->new({
        'client_loginid' => 'CR0010',
        'currency_code'  => 'USD',
    });

}
'expecting to create the instantiate AccountBase by client_loginid';

cmp_ok($base->account->account_record->client_loginid, 'eq', 'CR0010', 'Check if AccountBase will load the account class properly');

