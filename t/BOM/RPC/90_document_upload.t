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
    language    => 'EN',
    token       => $real_token,
    upload      => 'some_id',
    args        => {}
);

my %default_args = (
    document_id         => 'ABCD1234',
    document_type       => 'passport',
    document_format     => 'jpg',
    expected_checksum   => 'FileChecksum',
    expiration_date     => '2117-08-11',
    file_size           => 1,
);

my $result;
my $doc;
my $client_id;

use constant {
    EXP_DATE_PAST   => '2017-08-09',
    DOC_ID_2        => 'ABCD1235'
};

use constant MAX_FILE_SIZE => 3 * 2**20;

my $invalid_file_id = 1231531;

#########################################################
## Tests for argument error handling
#########################################################

subtest 'Error for invalid client token' => sub {
    my $custom_params = { token => $invalid_token };
    call_and_check_error($custom_params, 'The token is invalid.', 'check invalid token');
};

subtest 'Error for attemtping uploads on virtual account' => sub {
    my $custom_params = { token => $virtual_token };
    call_and_check_error($custom_params, "Virtual accounts don't require document uploads.", "don't allow virtual accounts to upload");
};

subtest 'Error for doc expiration date in the past' => sub {
    my $custom_params = { args => { expiration_date => EXP_DATE_PAST } };
    call_and_check_error($custom_params, 'Expiration date cannot be less than or equal to current date.', 'check expiration_date is before current date');
};

subtest 'Error for over-size file' => sub {
    my $custom_params = { args => { file_size => MAX_FILE_SIZE + 1 } };
    call_and_check_error($custom_params, 'Maximum file size reached. Maximum allowed is '.MAX_FILE_SIZE, 'over-size file is denied');
};

subtest 'Error for no document_id' => sub {
    my $custom_params = { args => { document_id => '' } };
    call_and_check_error($custom_params, 'Document ID is required.', 'document_id is required');
};


#########################################################
## Helper methods
#########################################################

sub call_and_check_error {
    my ($custom_params, $expected_err_message, $test_print_message) = @_;

    # Initialise default params
    my $params      = { %default_params };
    $params->{args} = { %default_args };
    
    # Customise params
    for my $key (keys $custom_params){
        $params->{$key} = $custom_params->{$key} unless $key eq 'args';
    }
    if ($custom_params->{args}){
        for my $key (keys $custom_params->{args}){
            $params->{args}->{$key} = $custom_params->{args}->{$key};
        }
    }
    
    # Call and check error
    $c->call_ok($method, $params)->has_error->error_message_is($expected_err_message, $test_print_message);
}

sub get_notification_email {
    my ($msg) = $mailbox->search(
        email   => 'authentications@binary.com',
        subject => qr/New uploaded document for: $client_id/
    );
    return $msg;
}

done_testing();
