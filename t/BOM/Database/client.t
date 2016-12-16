use strict;
use warnings;
use Test::More;

use BOM::Database::ClientDB;

my $details = {
	first_name => 'Bond',
	last_name => 'Lim',
	date_of_birth => '1932-09-07',
};

my $clientdb = BOM::Database::ClientDB->new({
    broker_code => 'CR'
});

my $res = $clientdb->getall_arrayref('SELECT row_to_json(u.*) FROM pg_user u  where usename=?;', ['postgres']);

ok (scalar @$res == 1, "check if array size is ok");
ok ($res->[0]->{usename} eq 'postgres', "check if hashref strcuture is ok");

$res = BOM::Database::ClientDB->new({broker_code => 'CR'})->get_duplicate_client($details);
cmp_ok($res, '>', 1, 'It finds duplicats');

$details->{first_name} = $details->{first_name} . ' ';
$res = BOM::Database::ClientDB->new({broker_code => 'CR'})->get_duplicate_client($details);
cmp_ok($res, '>', 1, 'It finds duplicats even with extra space');

$details->{first_name} = 'NAME NOT THERE';
$res = BOM::Database::ClientDB->new({broker_code => 'CR'})->get_duplicate_client($details);
cmp_ok($res, '==', 0, 'But it does not exists, it will return 0');

done_testing();
