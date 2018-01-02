use strict;
use warnings;
use BOM::Test::RPC::Client;
use Test::Most;
use Test::Mojo;
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Database::Model::OAuth;
use Email::Folder::Search;
use utf8;

my $mailbox = Email::Folder::Search->new('/tmp/default.mailbox');
$mailbox->init;

my $email       = 'dummy@binary.com';
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});
$test_client->email($email);
$test_client->save;

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $test_client->loginid);

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);

my $method = 'document_upload';
my $params = {
    language => 'EN',
    token    => 12345
};

# Invalid token shouldn't be allowed to upload.
$c->call_ok($method, $params)->has_error->error_message_is('The token is invalid.', 'check invalid token');

$params->{token} = $token;
# Valid token but virtual account.
$c->call_ok($method, $params)
    ->has_error->error_message_is("Virtual accounts don't require document uploads.", "don't allow virtual accounts to upload");

# Creating new real account.
$test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $test_client->loginid);

# For CR accounts.
$params->{token}  = $token;
$params->{upload} = "some_id";

my $args = {};
$params->{args} = $args;

$args->{expiration_date} = "2017-08-09";    # Expired documents.
$c->call_ok($method, $params)
    ->has_error->error_message_is('Expiration date cannot be less than or equal to current date.', 'check expiration_date is before current date');

# Unsuccessful finished upload
$args->{expiration_date} = "2117-08-11";    # 100 years is all I give you, humanity!
$c->call_ok($method, $params)
    ->has_error->error_message_is('Sorry, an error occurred while processing your request.', 'upload finished unsuccessfully');

$args->{document_type}   = "passport";
$args->{document_format} = "jpg";

# Error for no document_id
$c->call_ok($method, $params)->has_error->error_message_is('Document ID is required.', 'document_id is required');

$args->{document_id} = "ABCD1234";
my $result = $c->call_ok($method, $params)->result;
my ($doc) = $test_client->find_client_authentication_document(query => [id => $result->{file_id}]);
# Succesfully retrieved object from database.
is($doc->document_id, $args->{document_id}, 'document is saved in db');
is($doc->status,      'uploading',          'document status is set to uploading');

# Document with no expiration_date
$args->{expiration_date} = '';    # Document with no expiration_date
$c->call_ok($method, $params)->result;

my $checksum = 'FileChecksum';

$args = {
    status   => 'success',
    checksum => $checksum,
    file_id  => $result->{file_id}};
$params->{args} = $args;

$mailbox->clear;
my $client_id = uc $test_client->loginid;
$result = $c->call_ok($method, $params)->result;
#like(get_notification_email()->{body}, qr/New document was uploaded for the account: $client_id/, 'CS notification email was sent successfully');

($doc) = $test_client->find_client_authentication_document(query => [id => $result->{file_id}]);
is($doc->status,                                              'uploaded',           'document\'s status changed');
is($test_client->get_status('document_under_review')->reason, 'Documents uploaded', 'client\'s status changed');
ok(!$test_client->get_status('document_needs_action'), 'Document should not be in needs_action state');
ok $doc->file_name, 'Filename should not be empty';
is $doc->checksum, $checksum, 'Checksum should be added correctly';

# --- Upload a (different) doc into the same record to ensure CS team is only sent 1 email ---
$mailbox->clear;
$args->{checksum} = 'FileChecksum2';
$result = $c->call_ok($method, $params)->result;
ok(!get_notification_email(), 'CS notification email should only be sent once');

# --- Attempt with non-existent file ID ---
$args->{file_id} = 1231531;
$c->call_ok($method, $params)->has_error->error_message_is('Document not found.', 'error if document is not present');

sub get_notification_email {
    my ($msg) = $mailbox->search(
        email   => 'authentications@binary.com',
        subject => qr/New uploaded document for: $client_id/
    );
    return $msg;
}

done_testing();
