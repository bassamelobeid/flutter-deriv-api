#!perl

use strict;
use warnings;

use Data::Dumper;
use Test::More;
use Test::Deep;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client qw( create_client );

my $client = create_client('CR', undef, {binary_user_id => 1});
$client->set_default_account('USD');
$client->save();
my $dbh = $client->db->dbic->dbh;

my $test = 'BOM::User::Client->documents_expired returns undef if there are no documents';
is($client->documents_expired(), 0, $test);

$test = q{After call to start_document_upload, client has a single document, with an 'uploading' status};
my $SQL         = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?)';
my $sth_doc_new = $dbh->prepare($SQL);
$sth_doc_new->execute($client->loginid, 'testing1', 'PNG', 'yesterday', 55555, undef, 'none', 'front');
my $id1 = $sth_doc_new->fetch()->[0];
$SQL = 'SELECT id,status FROM betonmarkets.client_authentication_document WHERE client_loginid = ?';
my $sth_doc_info = $dbh->prepare($SQL);
$sth_doc_info->execute($client->loginid);
my $actual   = $sth_doc_info->fetchall_arrayref({});
my $expected = [{
        id     => $id1,
        status => 'uploading'
    }];
cmp_deeply($actual, $expected, $test);

$test = q{BOM::User::Client->documents_expired returns 0 if all documents are in 'uploading' status};
## This is neeeded to force $client to reload this relationship
## This will not work: $client->load( with => ['client_authentication_document']);
$client->client_authentication_document(undef);
is($client->documents_expired(), 0, $test);

$test = q{After call to finish_document_upload, document status changed to 'uploaded'};
$SQL  = 'SELECT * FROM betonmarkets.finish_document_upload(?)';
my $sth_doc_finish = $dbh->prepare($SQL);
$sth_doc_finish->execute($id1);
$sth_doc_info->execute($client->loginid);
$actual = $sth_doc_info->fetchall_arrayref({});
$expected->[0]{status} = 'uploaded';
cmp_deeply($actual, $expected, $test);

$test = q{BOM::User::Client->documents_expired returns 0 if document in 'uploaded' status and no expiration date};
$SQL  = 'UPDATE betonmarkets.client_authentication_document SET expiration_date = ? WHERE id = ?';
my $sth_doc_update = $dbh->prepare($SQL);
$sth_doc_update->execute(undef, $id1);
$client->client_authentication_document(undef);
is($client->documents_expired(), 0, $test);

$test = q{BOM::User::Client->documents_expired returns 0 if document has future expiration date};
$sth_doc_update->execute('tomorrow', $id1);
is($client->documents_expired(), 0, $test);

$test = q{BOM::User::Client->documents_expired returns 0 if document has an expiration date of today};
$sth_doc_update->execute('today', $id1);
$client->client_authentication_document(undef);
is($client->documents_expired(), 0, $test);

$test = q{BOM::User::Client->documents_expired returns 1 if document has an expiration date of yesterday};
$sth_doc_update->execute('yesterday', $id1);
$client->client_authentication_document(undef);
is($client->documents_expired(), 1, $test);

$test = q{BOM::User::Client->documents_expired returns 0 if document has an expiration date of the far future};
$sth_doc_update->execute('2999-01-01', $id1);
$client->client_authentication_document(undef);
is($client->documents_expired(), 0, $test);

$test = q{BOM::User::Client->documents_expired returns 1 if document has an expiration date of a long time ago};
$sth_doc_update->execute('epoch', $id1);
$client->client_authentication_document(undef);
is($client->documents_expired(), 1, $test);

$test = q{BOM::User::Client->documents_expired returns 0 if all documents have no expiration date};
## Create a second document
$sth_doc_new->execute($client->loginid, 'testing2', 'PNG', undef, 66666, undef, 'none', 'front');
my $id2 = $sth_doc_new->fetch()->[0];
$sth_doc_finish->execute($id2);
$SQL = 'UPDATE betonmarkets.client_authentication_document SET expiration_date = null WHERE client_loginid = ?';
$dbh->do($SQL, undef, $client->loginid);
$client->client_authentication_document(undef);
is($client->documents_expired(), 0, $test);

$test = q{BOM::User::Client->documents_expired returns 1 if only some document are expired};
$sth_doc_update->execute('yesterday', $id2);
$client->client_authentication_document(undef);
is($client->documents_expired(), 1, $test);

$test = q{BOM::User::Client->documents_expired returns 0 if only all documents expire in the future};
$sth_doc_update->execute('tomorrow', $id1);
$sth_doc_update->execute('tomorrow', $id2);
$client->client_authentication_document(undef);
is($client->documents_expired(), 0, $test);

done_testing();
