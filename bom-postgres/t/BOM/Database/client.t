#!perl

use strict;
use warnings;
use utf8;

use Test::More;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Database::ClientDB;

my $details = {
    first_name    => 'Bond',
    last_name     => 'Lim',
    date_of_birth => '1932-09-07',
    email         => 'ivan@regentmarkets.com',
};

my $clientdb = BOM::Database::ClientDB->new({broker_code => 'CR'});

my $res = $clientdb->getall_arrayref('SELECT row_to_json(u.*) FROM pg_user u  where usename=?;', ['postgres']);

ok(scalar @$res == 1,                  "check if array size is ok");
ok($res->[0]->{usename} eq 'postgres', "check if hashref strcuture is ok");

$res = BOM::Database::ClientDB->new({broker_code => 'CR'})->get_duplicate_client($details);
cmp_ok($res, '==', 0, 'no duplicates as email is same');

# make duplicate client
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});

$client->first_name($details->{first_name});
$client->last_name($details->{last_name});
$client->date_of_birth($details->{date_of_birth});
$client->save;

$details->{first_name} = $details->{first_name} . ' ';
$res = BOM::Database::ClientDB->new({broker_code => 'CR'})->get_duplicate_client($details);
cmp_ok($res, '>', 1, 'It finds duplicates even with extra space');

$details->{first_name} = 'NAME NOT THERE';
$res = BOM::Database::ClientDB->new({broker_code => 'CR'})->get_duplicate_client($details);
cmp_ok($res, '==', 0, 'But it does not exists, it will return 0');

$client->first_name($details->{first_name});
$client->save;

$client->status->set('withdrawal_locked', 'system', 'test');
$res = BOM::Database::ClientDB->new({broker_code => 'CR'})->get_duplicate_client($details);
cmp_ok($res, '>', 1, 'withdrawal_locked client is still flagged as duplicate');

$res = BOM::Database::ClientDB->new({broker_code => 'CR'})->get_duplicate_client({%$details, exclude_status => ['withdrawal_locked']});
cmp_ok($res, '==', 0, '...but not if that status is excluded');

$client->status->set('disabled', 'system', 'test');
$res = BOM::Database::ClientDB->new({broker_code => 'CR'})->get_duplicate_client($details);
cmp_ok($res, '==', 0, 'Client with disabled status is not flagged as duplicate');
$client->status->clear_disabled;

$client->status->set('duplicate_account', 'system', 'test');
$res = BOM::Database::ClientDB->new({broker_code => 'CR'})->get_duplicate_client($details);
cmp_ok($res, '==', 0, 'Client with duplicate_account status is not flagged as duplicate');

$client->status->set('tnc_approval', 'system', 'test');
$res = BOM::Database::ClientDB->new({broker_code => 'CR'})->get_duplicate_client($details);
cmp_ok($res, '==', 0, '...even when they have some other status');

subtest "unicode json in getall_arrayref" => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    $client->first_name('Василий');
    $client->last_name('Пупкин');
    $client->date_of_birth('1932-09-07');
    $client->save;
    my $r = $clientdb->getall_arrayref("select json_build_object('f', first_name, 'l', last_name) from betonmarkets.client where first_name = ?",
        ['Василий']);
    is $r->[0]->{f}, 'Василий';
    is $r->[0]->{l}, 'Пупкин';
};

done_testing();
