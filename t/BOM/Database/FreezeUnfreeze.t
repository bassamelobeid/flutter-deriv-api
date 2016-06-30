use Test::More tests => 8;
use Test::Exception;
use Test::NoWarnings;

use BOM::Database::DataMapper::Client;
use BOM::Platform::Transaction;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $loginid = 'CR0016';
my $client_data_mapper;

lives_ok {
    $client_data_mapper = BOM::Database::DataMapper::Client->new({
        client_loginid => $loginid,
    });
}
'Data mapper object created';

is(BOM::Platform::Transaction->freeze_client($loginid), 1, 'Client was locked successfully');

cmp_ok(scalar keys %{$client_data_mapper->locked_client_list()}, '==', 1, 'There is one locked client');

isnt(BOM::Platform::Transaction->freeze_client($loginid), 0, 'Can not lock client that is already stuck');

cmp_ok(scalar keys %{$client_data_mapper->locked_client_list()}, '==', 1, 'Still there is one locked client');

is(BOM::Platform::Transaction->unfreeze_client($loginid), 1, 'Client was unlocked successfully');

cmp_ok(scalar keys %{$client_data_mapper->locked_client_list()}, '==', 0, 'There is no locked client');

done_testing(8);
