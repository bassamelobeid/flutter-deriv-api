#!/etc/rmg/bin/perl
use strict;
use warnings;
use Test::More $ENV{AUTHOR_TESTING} ? (tests => 8) : (skip_all => 'Author tests. Set AUTHOR_TESTING to run it.');
use Test::Exception;
use BOM::Database::Model::Account;
use BOM::Database::Model::Constants;

use BOM::Test::Data::Utility::UnitTestDatabase;

my $unit_test_db = BOM::Test::Data::Utility::UnitTestDatabase->instance;
my $schema_path  = $unit_test_db->changesets_location;

throws_ok {
    $unit_test_db->changesets_location('ffffffffffffff');
    $unit_test_db->prepare_unit_test_database;
}
qr/No such file or directory at .*Migration.pm/, 'expecting to die if it fails to inantiate the DB';

$unit_test_db->changesets_location($schema_path);

$unit_test_db = BOM::Test::Data::Utility::UnitTestDatabase->instance;
lives_ok {
    $unit_test_db->prepare_unit_test_database;
}
'expecting to generate the test database';

{
    local $SIG{__WARN__} = sub { };
    lives_ok {
        $unit_test_db = BOM::Test::Data::Utility::UnitTestDatabase->instance;
        $unit_test_db->prepare_unit_test_database;
    }
    'expecting to deal with a second call to this function';
}

my $client_loginid = 'CR0010';

my $connection_builder;
my $account;

lives_ok {
    $connection_builder = BOM::Database::ClientDB->new({
        broker_code => 'CR',
    });

    $account = BOM::Database::Model::Account->new({
            'data_object_params' => {
                'client_loginid' => $client_loginid,
                'currency_code'  => 'USD'
            },
            db => $connection_builder->db
        });

    $account->load({'load_params' => {speculative => 1}});
}
'expecting to create the required account models for transfer';
