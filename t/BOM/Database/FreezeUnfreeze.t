use Test::Warnings;
use Test::More (tests => 5);
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

ok(!$client_db->freeze, 'Can not lock client that is already stuck');

ok($client_db->unfreeze, 'Client was unlocked successfully');

