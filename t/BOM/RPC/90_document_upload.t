use strict;
use warnings;

use BOM::Test::RPC::Client;
use Test::More;
use Test::Mojo;
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Database::Model::OAuth;
use Email::Folder::Search;
use List::Util qw( all );

#########################################################
## Setup test RPC
#########################################################

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);

#########################################################
## Setup mailbox
#########################################################

my $mailbox = Email::Folder::Search->new('/tmp/default.mailbox');
$mailbox->init;

#########################################################
## Setup clients
#########################################################

my $email       = 'dummy@binary.com';

my $virtual_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});
$virtual_client->email($email);
$virtual_client->save;

my $real_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});

#########################################################
## Setup tokens
#########################################################

my ($virtual_token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $virtual_client->loginid);
my ($real_token)    = BOM::Database::Model::OAuth->new->store_access_token_only(1, $real_client->loginid);
my $invalid_token   = 12345;

#########################################################
## Setup test paramaters
#########################################################

my $method          = 'document_upload';

my %default_params = (
    language => 'EN'
);

my %default_real_params = (
    %default_params,
    token => $real_token,
    upload => "some_id",
    args => {}
);

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

use constant MAX_FILE_SIZE => 3 * 2**20;

my $invalid_file_id = 1231531;

#########################################################
## Test cases start here
#########################################################

subtest "Invalid token shouldn't be allowed to upload" => sub {
    my $params = { %default_params };
    $params->{token}  = $invalid_token;
    $c->call_ok($method, $params)->has_error->error_message_is('The token is invalid.', 'check invalid token');
};

subtest 'Valid token but virtual account' => sub {
    my $params = { %default_params };
    $params->{token} = $virtual_token;
    $c->call_ok($method, $params)
        ->has_error->error_message_is("Virtual accounts don't require document uploads.", "don't allow virtual accounts to upload");
};

subtest 'Expired documents' => sub {
    my $params = { %default_real_params };
    $params->{args}->{expiration_date} = EXP_DATE_PAST;
    $c->call_ok($method, $params)
        ->has_error->error_message_is('Expiration date cannot be less than or equal to current date.', 'check expiration_date is before current date');
};

subtest 'Error for over-size file' => sub {
    my $params = { %default_real_params };
    $params->{args}->{file_size} = MAX_FILE_SIZE + 1;
    $c->call_ok($method, $params)->has_error->error_message_is('Maximum file size reached. Maximum allowed is '.MAX_FILE_SIZE, 'over-size file is denied');
};

#########################################################
## Helper methods
#########################################################

sub get_notification_email {
    my ($msg) = $mailbox->search(
        email   => 'authentications@binary.com',
        subject => qr/New uploaded document for: $client_id/
    );
    return $msg;
}

done_testing();
