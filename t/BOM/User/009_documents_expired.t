#!perl

use strict;
use warnings;

use Data::Dumper;
use Test::More;
use Test::Deep;
use Test::MockModule;
use BOM::User;

use Date::Utility;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client qw( create_client );

my $user_client = BOM::User->create(
    email          => 'abc@binary.com',
    password       => BOM::User::Password::hashpw('jskjd8292922'),
    email_verified => 1,
);
my $client = create_client('CR');
$user_client->add_client($client);
$client->set_default_account('USD');
$client->save();
my $dbh = $client->db->dbic->dbh;

my $test = 'BOM::User::Client->documents_expired returns undef if there are no documents';
is($client->documents_expired(), 0, $test);

$test = q{After call to start_document_upload, client has a single document, with an 'uploading' status};
my $SQL         = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?)';
my $sth_doc_new = $dbh->prepare($SQL);
$sth_doc_new->execute($client->loginid, 'passport', 'PNG', 'yesterday', 55555, '75bada1e034d13b417083507db47ee4a', 'none', 'front');
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
$sth_doc_new->execute($client->loginid, 'passport', 'PNG', undef, 66666, '204a5098dac0dc176c88e4ab5312dbd5', 'none', 'front');
my $id2 = $sth_doc_new->fetch()->[0];

$SQL = 'SELECT COUNT(*) from betonmarkets.client_authentication_document WHERE client_loginid = ?';
my $doc_nums = $dbh->prepare($SQL);
$doc_nums->execute($client->loginid);
my $total_docs = $doc_nums->fetchrow_array();

is($total_docs, 2, 'Two documents uploaded');

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

$test = q{BOM::User::Client->documents_expired returns 1 if documents within future date limit};
my $test_date = Date::Utility->new()->plus_time_interval('2d');
is($client->documents_expired($test_date), 1, $test);

$SQL         = 'SELECT * FROM betonmarkets.start_document_upload(?,?,?,?,?,?,?,?)';
$sth_doc_new = $dbh->prepare($SQL);
$sth_doc_new->execute($client->loginid, 'bankstatement', 'PNG', 'yesterday', 65555, '75bada1e034d13b417083507db47ee4b', 'none', 'front');
$id1            = $sth_doc_new->fetch()->[0];
$SQL            = 'SELECT * FROM betonmarkets.finish_document_upload(?)';
$sth_doc_finish = $dbh->prepare($SQL);
$sth_doc_finish->execute($id1);

my $documents = $client->documents_uploaded();
cmp_deeply(
    $documents,
    {
        proof_of_identity => {
            documents => {
                "CR10000.passport.270744401_front.PNG" => {
                    expiry_date => $documents->{proof_of_identity}{documents}{'CR10000.passport.270744401_front.PNG'}{expiry_date},
                    format      => "PNG",
                    id          => 55555,
                    status      => "uploaded",
                    type        => "passport",
                },
                "CR10000.passport.270744421_front.PNG" => {
                    expiry_date => $documents->{proof_of_identity}{documents}{'CR10000.passport.270744421_front.PNG'}{expiry_date},
                    format      => "PNG",
                    id          => 66666,
                    status      => "uploaded",
                    type        => "passport",
                },
            },
            is_pending          => 1,
            is_expired          => 0,
            minimum_expiry_date => $documents->{proof_of_identity}{documents}{'CR10000.passport.270744421_front.PNG'}{expiry_date},
        },
        proof_of_address => {
            documents => {
                "CR10000.bankstatement.270744441_front.PNG" => {
                    expiry_date => $documents->{proof_of_address}{documents}{'CR10000.bankstatement.270744441_front.PNG'}{expiry_date},
                    format      => "PNG",
                    id          => 65555,
                    status      => "uploaded",
                    type        => "bankstatement",
                },
            },
            is_pending          => 1,
            is_expired          => 1,
            minimum_expiry_date => $documents->{proof_of_address}{documents}{'CR10000.bankstatement.270744441_front.PNG'}{expiry_date},
        },
    },
    'correct structure for client documents'
);

my $module = Test::MockModule->new('BOM::User::Client');
$module->mock('authentication_status', sub { 'needs_action' });

$documents = $client->documents_uploaded();
cmp_deeply(
    $documents,
    {
        proof_of_identity => {
            documents => {
                "CR10000.passport.270744401_front.PNG" => {
                    expiry_date => $documents->{proof_of_identity}{documents}{'CR10000.passport.270744401_front.PNG'}{expiry_date},
                    format      => "PNG",
                    id          => 55555,
                    status      => "uploaded",
                    type        => "passport",
                },
                "CR10000.passport.270744421_front.PNG" => {
                    expiry_date => $documents->{proof_of_identity}{documents}{'CR10000.passport.270744421_front.PNG'}{expiry_date},
                    format      => "PNG",
                    id          => 66666,
                    status      => "uploaded",
                    type        => "passport",
                },
            },
            is_pending          => 1,
            is_expired          => 0,
            minimum_expiry_date => $documents->{proof_of_identity}{documents}{'CR10000.passport.270744421_front.PNG'}{expiry_date},
        },
        proof_of_address => {
            documents => {
                "CR10000.bankstatement.270744441_front.PNG" => {
                    expiry_date => $documents->{proof_of_address}{documents}{'CR10000.bankstatement.270744441_front.PNG'}{expiry_date},
                    format      => "PNG",
                    id          => 65555,
                    status      => "uploaded",
                    type        => "bankstatement",
                },
            },
            is_expired          => 1,
            minimum_expiry_date => $documents->{proof_of_address}{documents}{'CR10000.bankstatement.270744441_front.PNG'}{expiry_date},
            is_rejected         => 1,
        },
    },
    'correct structure for client documents with authentication status as needs_action'
);

$module->mock('authentication_status', sub { 'under_review' });

$documents = $client->documents_uploaded();
cmp_deeply(
    $documents,
    {
        proof_of_identity => {
            documents => {
                "CR10000.passport.270744401_front.PNG" => {
                    expiry_date => $documents->{proof_of_identity}{documents}{'CR10000.passport.270744401_front.PNG'}{expiry_date},
                    format      => "PNG",
                    id          => 55555,
                    status      => "uploaded",
                    type        => "passport",
                },
                "CR10000.passport.270744421_front.PNG" => {
                    expiry_date => $documents->{proof_of_identity}{documents}{'CR10000.passport.270744421_front.PNG'}{expiry_date},
                    format      => "PNG",
                    id          => 66666,
                    status      => "uploaded",
                    type        => "passport",
                },
            },
            is_pending          => 1,
            is_expired          => 0,
            minimum_expiry_date => $documents->{proof_of_identity}{documents}{'CR10000.passport.270744421_front.PNG'}{expiry_date},
        },
        proof_of_address => {
            documents => {
                "CR10000.bankstatement.270744441_front.PNG" => {
                    expiry_date => $documents->{proof_of_address}{documents}{'CR10000.bankstatement.270744441_front.PNG'}{expiry_date},
                    format      => "PNG",
                    id          => 65555,
                    status      => "uploaded",
                    type        => "bankstatement",
                },
            },
            is_expired          => 1,
            minimum_expiry_date => $documents->{proof_of_address}{documents}{'CR10000.bankstatement.270744441_front.PNG'}{expiry_date},
            is_pending          => 1,
        },
    },
    'correct structure for client documents with authentication status as under_review'
);

$module->unmock_all();

done_testing();
