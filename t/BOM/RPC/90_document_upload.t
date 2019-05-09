use strict;
use warnings;

use BOM::Test::RPC::Client;
use Test::More;
use Test::Mojo;
use Test::Warn;
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Database::Model::OAuth;
use List::Util qw( all );
use BOM::RPC::v3::DocumentUpload qw(MAX_FILE_SIZE);

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC::Transport::HTTP')->app->ua);

# Set up clients

my $email = 'dummy@binary.com';

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

my $method = 'document_upload';

my %default_params = (
    language => 'EN',
    token    => $real_token,
    upload   => 'some_id',
    args     => {});

my %default_args = (
    document_id       => 'ABCD1234',
    document_type     => 'passport',
    document_format   => 'jpg',
    expected_checksum => 'FileChecksum',
    expiration_date   => '2117-08-11',
    file_size         => 1,
);

use constant {
    EXP_DATE_PAST   => '2017-08-09',
    INVALID_FILE_ID => -1,
};

#########################################################
## Tests for initial argument error handling
#########################################################

subtest 'Error for invalid client token' => sub {
    my $custom_params = {token => $invalid_token};
    call_and_check_error($custom_params, 'The token is invalid.', 'check invalid token');
};

subtest 'Error for attempting uploads on virtual account' => sub {
    my $custom_params = {token => $virtual_token};
    call_and_check_error($custom_params, "Virtual accounts don't require document uploads.", "don't allow virtual accounts to upload");
};

subtest 'Error for doc expiration date in the past' => sub {
    my $custom_params = {args => {expiration_date => EXP_DATE_PAST}};
    call_and_check_error(
        $custom_params,
        'Expiration date cannot be less than or equal to current date.',
        'check expiration_date is before current date'
    );
};

subtest 'Error for over-size file' => sub {
    my $custom_params = {args => {file_size => MAX_FILE_SIZE + 1}};
    call_and_check_error($custom_params, 'Maximum file size reached. Maximum allowed is ' . MAX_FILE_SIZE, 'over-size file is denied');
};

# Only applies if document_type is passport, proofid, or driverslicense
subtest 'Error for no document_id' => sub {
    my $custom_params = {args => {document_id => ''}};
    call_and_check_error($custom_params, 'Document ID is required.', 'document_id is required');
};

# Only applies if document_type is passport, proofid, or driverslicense
subtest 'Error for no expiration_date' => sub {
    my $custom_params = {args => {expiration_date => ''}};
    call_and_check_error($custom_params, 'Expiration date is required.', 'expiration_date is required');
};

# Applies for any type not of passport, proofid, or driverslicense
subtest 'No error for no document_id and expiration_date' => sub {
    my $custom_params = {
        args => {
            document_id     => '',
            expiration_date => '',
            document_type   => 'proofaddress'
        }};
    start_successful_upload($real_client, $custom_params);
};

subtest 'Generic upload fail test' => sub {
    my $custom_params = {
        args => {
            document_type   => '',
            document_format => ''
        }};
    call_and_check_error($custom_params, 'Sorry, an error occurred while processing your request.', 'upload finished unsuccessfully');
};

subtest 'Error for calling success with non-existent file ID' => sub {
    my $custom_params = {
        args => {
            status  => 'success',
            file_id => INVALID_FILE_ID,
            # These need to be blanked or RPC will try to start an upload
            document_type   => '',
            document_format => ''
        }};
    call_and_check_error($custom_params, 'Sorry, an error occurred while processing your request.', 'error if document is not present');
};

#########################################################
## Tests for successful upload
#########################################################

subtest 'Basic upload test sequence' => sub {

    my $file_id;
    my $checksum = $default_args{expected_checksum};

    subtest 'Start upload with all defaults' => sub {
        $file_id = start_successful_upload($real_client);
    };

    subtest 'Finish upload and verify CS notification email is receieved' => sub {
        finish_successful_upload($real_client, $file_id, $checksum, 1);
    };

    subtest 'Call finish again to ensure CS team is only sent 1 email' => sub {
        finish_successful_upload($real_client, $file_id, $checksum, 0);
    };
};

#########################################################
## Tests for upload fails
#########################################################

subtest 'Attempt to upload file with same checksum as "Basic upload test sequence"' => sub {
    call_and_check_error({}, 'Document already uploaded.', 'error if same document is uploaded twice');
};

#########################################################
## Audit test (keep this last)
#########################################################

subtest 'Check audit information after all above upload requests' => sub {
    my $result = $real_client->db->dbic->run(
        fixup => sub {
            $_->selectall_arrayref('SELECT pg_userid, remote_addr FROM audit.client_authentication_document');
        });

    ok(all { $_->[0] eq 'system' and $_->[1] eq '127.0.0.1/32' } @$result), 'Check staff and staff IP for all audit info';
};

#########################################################
## Helper methods
#########################################################

sub start_successful_upload {
    my ($client, $custom_params) = @_;

    # Initialise default params
    my $params = {%default_params};
    $params->{args} = {%default_args};

    # Customise params
    customise_params($params, $custom_params) if $custom_params;

    # Call to start upload
    my $result = $c->call_ok($method, $params)->has_no_error->result;

    # Check doc is entered into database
    my ($doc) = $client->find_client_authentication_document(query => [id => $result->{file_id}]);
    is($doc->document_id, $params->{args}->{document_id}, 'document is saved in db');
    is($doc->status, 'uploading', 'document status is set to uploading');

    return $result->{file_id};
}

sub finish_successful_upload {
    my ($client, $file_id, $checksum, $mail_expected) = @_;

    # Setup call paramaters
    my $params = {%default_params};
    $params->{args} = {
        status  => 'success',
        file_id => $file_id
    };

    # Call successful upload
    my $result = $c->call_ok($method, $params)->has_no_error->result;

    # Check doc is updated in database properly
    my ($doc) = $client->find_client_authentication_document(query => [id => $result->{file_id}]);
    is($doc->status, 'uploaded', 'document\'s status changed');
    ok $doc->file_name, 'Filename should not be empty';
    is $doc->checksum, $checksum, 'Checksum should be added correctly';

    # Check client status is correct
    ok($client->authentication_status eq 'under_review', 'Document should be under_review');

}

sub call_and_check_error {
    my ($custom_params, $expected_err_message, $test_print_message) = @_;

    # Initialise default params
    my $params = {%default_params};
    $params->{args} = {%default_args};

    # Customise params
    customise_params($params, $custom_params);

    # Call and check error
    $c->call_ok($method, $params)->has_error->error_message_is($expected_err_message, $test_print_message);
}

sub customise_params {
    my ($params, $custom_params) = @_;

    for my $key (keys %$custom_params) {
        $params->{$key} = $custom_params->{$key} unless $key eq 'args';
    }
    if ($custom_params->{args}) {
        for my $key (keys %{$custom_params->{args}}) {
            $params->{args}->{$key} = $custom_params->{args}->{$key};
        }
    }
}

done_testing();
