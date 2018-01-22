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

my $method          = 'document_upload';
my $params          = { language => 'EN' };
my $args            = {};
my $result;
my $doc;
my $client_id;

use constant {
    DOC_TYPE        => 'passport',
    DOC_FORMAT      => 'jpg',
    CHECKSUM        => 'FileChecksum',
    EXP_DATE_PAST   => '2017-08-09',
    EXP_DATE_FUTURE => '2117-08-11',
    DOC_ID_1        => 'ABCD1234',
    DOC_ID_2        => 'ABCD1235'
};

my $invalid_token   = 12345;
my $invalid_file_id = 1231531;

subtest "Invalid token shouldn't be allowed to upload" => sub {
    $params->{token}  = $invalid_token;
    $c->call_ok($method, $params)->has_error->error_message_is('The token is invalid.', 'check invalid token');
};

subtest 'Valid token but virtual account' => sub {
    $params->{token} = $token;
    $c->call_ok($method, $params)
        ->has_error->error_message_is("Virtual accounts don't require document uploads.", "don't allow virtual accounts to upload");
};

# ------- START Create real currency account --------
# Creating new real account.
$test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $test_client->loginid);

# For CR accounts.
$params->{token}  = $token;
$params->{upload} = "some_id";

$params->{args} = $args;
# -------  END Create real currency account  --------

subtest 'Expired documents' => sub {
    $args->{expiration_date} = EXP_DATE_PAST;    # Expired documents.
    $c->call_ok($method, $params)
        ->has_error->error_message_is('Expiration date cannot be less than or equal to current date.', 'check expiration_date is before current date');
};

subtest 'Unsuccessful finished upload' => sub {
    $args->{expiration_date} = EXP_DATE_FUTURE;    # 100 years is all I give you, humanity!
    $c->call_ok($method, $params)
        ->has_error->error_message_is('Sorry, an error occurred while processing your request.', 'upload finished unsuccessfully');
};

subtest 'Error for no document_id' => sub {
    $args->{document_type}   = DOC_TYPE;
    $args->{document_format} = DOC_FORMAT;
    $args->{expected_checksum} = CHECKSUM;
    
    $c->call_ok($method, $params)->has_error->error_message_is('Document ID is required.', 'document_id is required');
    
    $args->{document_id} = DOC_ID_1;
    $result = $c->call_ok($method, $params)->result;
    ($doc) = $test_client->find_client_authentication_document(query => [id => $result->{file_id}]);
    # Succesfully retrieved object from database.
    is($doc->document_id, $args->{document_id}, 'document is saved in db');
    is($doc->status,      'uploading',          'document status is set to uploading');
};

subtest 'Document with no expiration_date' => sub {
    $args->{expiration_date} = '';    # Document with no expiration_date
    $c->call_ok($method, $params)->result;
};

subtest 'Upload doc and send CS notification email' => sub {
    $args = {
        status   => 'success',
        file_id  => $result->{file_id}};
    $params->{args} = $args;
    
    $mailbox->clear;
    $client_id = uc $test_client->loginid;
    $result = $c->call_ok($method, $params)->result;
    like(get_notification_email()->{body}, qr/New document was uploaded for the account: $client_id/, 'CS notification email was sent successfully');
};

subtest 'Status and checksum of newly uploaded document' => sub {
    ($doc) = $test_client->find_client_authentication_document(query => [id => $result->{file_id}]);
    is($doc->status,                                              'uploaded',           'document\'s status changed');
    is($test_client->get_status('document_under_review')->reason, 'Documents uploaded', 'client\'s status changed');
    ok(!$test_client->get_status('document_needs_action'), 'Document should not be in needs_action state');
    ok $doc->file_name, 'Filename should not be empty';
    is $doc->checksum, CHECKSUM, 'Checksum should be added correctly';
};

subtest 'Call finish again to ensure CS team is only sent 1 email' => sub {
    $mailbox->clear;
    $result = $c->call_ok($method, $params)->result;
    ok(!get_notification_email(), 'CS notification email should only be sent once');
};

subtest 'Attempt with non-existent file ID' => sub {
    $args->{file_id} = $invalid_file_id;
    $c->call_ok($method, $params)->has_error->error_message_is('Document not found.', 'error if document is not present');
};

subtest 'Attempt to upload same document again (checksum collision) with different document ID' => sub {
    $args = {
        document_type     => DOC_TYPE,
        document_format   => DOC_FORMAT,
        expiration_date   => EXP_DATE_FUTURE,
        document_id       => DOC_ID_2,
        expected_checksum => CHECKSUM
    };
    $params->{args} = $args;
    $result = $c->call_ok($method, $params)->result;
    # Upload will commence and be blocked at finish

    $args = {
        status   => 'success',
        file_id  => $result->{file_id}};
    $params->{args} = $args;
    $c->call_ok($method, $params)->has_error->error_message_is('Document already uploaded.', 'error if same document is uploaded twice');
};

sub get_notification_email {
    my ($msg) = $mailbox->search(
        email   => 'authentications@binary.com',
        subject => qr/New uploaded document for: $client_id/
    );
    return $msg;
}

done_testing();
