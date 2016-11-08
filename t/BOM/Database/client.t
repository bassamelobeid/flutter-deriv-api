use strict;
use warnings;
use Test::More;

use BOM::Database::ClientDB;

my $clientdb = BOM::Database::ClientDB->new({broker_code => 'CR'});

my $res = $clientdb->getall_arrayref('SELECT row_to_json(u.*) FROM pg_user u  where usename=?;', ['postgres']);

ok(scalar @$res == 1,                  "check if array size is ok");
ok($res->[0]->{usename} eq 'postgres', "check if hashref strcuture is ok");

done_testing();
