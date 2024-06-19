#!perl

use strict;
use warnings;

use Test::More;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Database::ClientDB;
use BOM::User::Client;

# In COMPATIBLE_MODE we assume the old behavior of calling
# set_staff right before saving a Rose object.
use constant COMPATIBLE_MODE => 0;

sub get_audit {
    my $loginid  = shift;
    my $clientdb = BOM::Database::ClientDB->new({broker_code => 'CR'});

    return $clientdb->db->dbic->run(
        sub {
            $_->selectall_arrayref(<<'SQL', undef, $loginid);
SELECT operation, pg_userid, remote_addr
  FROM audit.client
 WHERE loginid=?
 ORDER BY stamp ASC
SQL
        });
}

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
my $loginid = $client->loginid;

note 'loginid=' . $loginid;

is_deeply get_audit($loginid), [[qw!INSERT system 127.0.0.1/32!],], 'audit records after creating a new client';

@ENV{qw/AUDIT_STAFF_NAME AUDIT_STAFF_IP/} = qw/tf 192.168.12.24/;

$client->comment('comment');
$client->save;

# NOTE: for future changes, this test is something we can sacrifice.
is_deeply get_audit($loginid), [[qw!INSERT system 127.0.0.1/32!], [qw!UPDATE tf 192.168.12.24/32!],],
    'audit records after updating client (envvars are respected even though DB connection is reused)';

# since we don't re-create the client object, this is equivalent to
# pgbouncer being restarted
BOM::Database::Rose::DB->db_cache->finish_request_cycle;

$client->comment('comment');
$client->save;

is_deeply get_audit($loginid), [[qw!INSERT system 127.0.0.1/32!], [qw!UPDATE tf 192.168.12.24/32!], [qw!UPDATE tf 192.168.12.24/32!],],
    'new connection now uses envvars';

# Here we explicitly acquire a new connection.
undef $client;
@ENV{qw/AUDIT_STAFF_NAME AUDIT_STAFF_IP/} = qw/xx 192.168.12.25/;
BOM::Database::Rose::DB->db_cache->finish_request_cycle;
$client = BOM::User::Client->new({loginid => $loginid});

$client->comment('comment');
$client->save;

is_deeply get_audit($loginid),
    [[qw!INSERT system 127.0.0.1/32!], [qw!UPDATE tf 192.168.12.24/32!], [qw!UPDATE tf 192.168.12.24/32!], [qw!UPDATE xx 192.168.12.25/32!],],
    'new envvars';

delete @ENV{qw/AUDIT_STAFF_NAME AUDIT_STAFF_IP/};
BOM::Database::Rose::DB->db_cache->finish_request_cycle;

$client->comment('comment');
$client->save;

is_deeply get_audit($loginid),
    [
    [qw!INSERT system 127.0.0.1/32!], [qw!UPDATE tf 192.168.12.24/32!], [qw!UPDATE tf 192.168.12.24/32!], [qw!UPDATE xx 192.168.12.25/32!],
    [qw!UPDATE system 127.0.0.1/32!],
    ],
    'envvars deleted';

@ENV{qw/AUDIT_STAFF_NAME AUDIT_STAFF_IP/} = qw/mt 192.168.12.26/;
BOM::Database::Rose::DB->db_cache->finish_request_cycle;

{
    BOM::Database::ClientDB->new({broker_code => 'CR'})->db->dbic->run(
        sub {
            $_->do(<<'SQL', undef, 'blah', $loginid);
UPDATE betonmarkets.client
   SET comment=?
 WHERE loginid=?
SQL
        });
}

is_deeply get_audit($loginid),
    [
    [qw!INSERT system 127.0.0.1/32!], [qw!UPDATE tf 192.168.12.24/32!],
    [qw!UPDATE tf 192.168.12.24/32!], [qw!UPDATE xx 192.168.12.25/32!],
    [qw!UPDATE system 127.0.0.1/32!], COMPATIBLE_MODE ? [qw!UPDATE ?!, undef] : [qw!UPDATE mt 192.168.12.26/32!],
    ],
    'update client object without Rose';

done_testing();
