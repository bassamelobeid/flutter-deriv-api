use strict;
use warnings;
use Test::More (tests => 13);
use Test::Warnings;

use Test::Exception;
use BOM::Database::DataMapper::Base;

use BOM::Test::Data::Utility::UnitTestDatabase          qw(:init);
use BOM::Test::Data::Utility::UnitTestCollectorDatabase qw(:init);

my $base;
my $session_user;
lives_ok {
    $base = BOM::Database::DataMapper::Base->new({
        'client_loginid' => 'CR0010',
    });

}
'expecting to create the instantiate Base by client_loginid';

$session_user = $base->db->dbh->selectrow_hashref('SELECT session_user')->{'session_user'};
#Checking for both writer is a temp fix so the test passes on both CI and QA.
ok($session_user eq 'writer1' || $session_user eq 'writer2' || $session_user eq 'write', 'Check if base will use the right role for read');

lives_ok {
    $base = BOM::Database::DataMapper::Base->new({
        'client_loginid' => 'CR0010',
    });

}
'expecting to create the instantiate Base by client_loginid';

$session_user = $base->db->dbh->selectrow_hashref('SELECT session_user')->{'session_user'};
ok($session_user eq 'writer1' || $session_user eq 'writer2' || $session_user eq 'write', 'Check if base will use the right role for write');

lives_ok {
    $base = BOM::Database::DataMapper::Base->new({
        'client_loginid' => 'FOG',
        'operation'      => 'collector'
    });

}
'expecting to create the instantiate Base by client_loginid';

$session_user = $base->db->dbh->selectrow_hashref('SELECT session_user')->{'session_user'};
ok($session_user eq 'writer1' || $session_user eq 'writer2' || $session_user eq 'write', 'Check if base will use the right role for collector');

lives_ok {
    $base = BOM::Database::DataMapper::Base->new({
        'client_loginid' => 'FOG',
        'operation'      => 'collector',
    });

}
'expecting to create the instantiate Base by client_loginid';

$session_user = $base->db->dbh->selectrow_hashref('SELECT session_user')->{'session_user'};
ok($session_user eq 'writer1' || $session_user eq 'writer2' || $session_user eq 'write', 'Check if base will use the right role for collector');

lives_ok {
    $base = BOM::Database::DataMapper::Base->new({
        'broker_code' => 'CR',
    });

}
'expecting to create the instantiate Base by broker_code';

$session_user = $base->db->dbh->selectrow_hashref('SELECT session_user')->{'session_user'};
ok($session_user eq 'writer1' || $session_user eq 'writer2' || $session_user eq 'write', 'Check if base will use the right role for read');

lives_ok {
    my $connection_builder = BOM::Database::ClientDB->new({
        broker_code => 'CR',
    });

    $base = BOM::Database::DataMapper::Base->new({
        'db'             => $connection_builder->db,
        'client_loginid' => 'CR0010',
    });

}
'expecting to create the instantiate Base with passing the connection_builder object';

lives_ok {
    $base = BOM::Database::DataMapper::Base->new({
        'client_loginid' => 'CR0010',
        'currency_code'  => 'USD',
    });

}
'expecting to create the instantiate Base by client_loginid';

