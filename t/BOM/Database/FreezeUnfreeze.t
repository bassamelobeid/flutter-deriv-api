use Test::More tests => 7;
use Test::Exception;

use BOM::Database::ClientDB;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $loginid = 'CR0016';
my $client_db;

lives_ok {
    $client_db = BOM::Database::ClientDB->new({
        client_loginid => $loginid,
    });
}
'Data mapper object created';

ok($client_db->freeze, 'Client was locked successfully');

cmp_ok(scalar keys %{$client_db->locked_client_list()}, '==', 1, 'There is one locked client');

ok(!$client_db->freeze, 'Can not lock client that is already stuck');

cmp_ok(scalar keys %{$client_db->locked_client_list()}, '==', 1, 'Still there is one locked client');

ok($client_db->unfreeze, 'Client was unlocked successfully');

cmp_ok(scalar keys %{$client_db->locked_client_list()}, '==', 0, 'There is no locked client');

done_testing(7);
