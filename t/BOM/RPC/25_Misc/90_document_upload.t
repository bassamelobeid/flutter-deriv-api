use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Test::Warn;
use Test::Fatal;
use Test::Deep                                 qw/cmp_deeply/;
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Database::Model::OAuth;
use List::Util                   qw( all any );
use BOM::RPC::v3::DocumentUpload qw(MAX_FILE_SIZE);
use Array::Utils                 qw(array_minus);
use Test::MockModule;
use BOM::Test::RPC::QueueClient;

my $c = BOM::Test::RPC::QueueClient->new();

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
    document_id              => 'ABCD1234',
    document_type            => 'passport',
    document_format          => 'jpg',
    expected_checksum        => 'FileChecksum',
    expiration_date          => '2117-08-11',
    file_size                => 1,
    document_issuing_country => 'br'
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
## Tests for mandatory issuing country
#########################################################

subtest 'Attempt to upload POI document without an issuing country' => sub {
    call_and_check_error({
            args => {
                %default_args,
                expected_checksum        => 'new doc',
                document_id              => 'qwerty101',
                document_issuing_country => undef
            }
        },
        'Issuing country is mandatory for proof of identity',
        'mandatory issuing country'
    );
};

#########################################################
## Tests for upload fails
#########################################################

subtest 'Attempt to upload file with same checksum as "Basic upload test sequence"' => sub {
    call_and_check_error({}, 'Document already uploaded.', 'error if same document is uploaded twice');
};

#########################################################
## Tests for limit of uploaded documents reached per day
#########################################################

subtest 'Limit of uploaded documents reached' => sub {
    my $redis = BOM::Config::Redis::redis_replicated_write();
    my $key   = 'MAX_UPLOADS_KEY::' . $real_client->binary_user_id;

    $redis->set($key, 21,);

    my $error_params = +{%default_params};

    call_and_check_error($error_params, 'Maximum upload attempts per day reached. Maximum allowed is 20', 'Upload limit reached');
};

#########################################################
## Tests for datadog metrics on number of uploaded docs
#########################################################

subtest 'DD metrics for docs uploaded' => sub {
    my $redis = BOM::Config::Redis::redis_replicated_write();
    my $key   = 'MAX_UPLOADS_KEY::' . $real_client->binary_user_id;
    $redis->del($key);

    my $dog_mock = Test::MockModule->new('DataDog::DogStatsd::Helper');
    my @metrics;
    $dog_mock->mock(
        'stats_inc',
        sub {
            push @metrics, @_;

            return 1;
        });

    my $file_id = start_successful_upload(
        $real_client,
        {
            args => {
                expected_checksum => 'test1111',
                document_id       => '12341234',
            }});
    finish_successful_upload($real_client, $file_id, 'test1111', 1);

    ok $redis->ttl($key) > 0, 'there is a ttl';

    cmp_deeply + {@metrics},
        +{
        'bom_rpc.v_3.call.count'     => {tags => ['rpc:document_upload', 'stream:general']},
        'bom_rpc.doc_upload_counter' => {tags => ['loginid:' . $real_client->loginid]},
        },
        'Expected dd metrics';
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

subtest 'Siblings accounts sync' => sub {
    subtest 'MLT to MF' => sub {
        my $mlt_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MLT',
        });
        my $mf_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MF',
        });
        my ($mlt_token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $mlt_client->loginid);
        my ($mf_token)  = BOM::Database::Model::OAuth->new->store_access_token_only(1, $mf_client->loginid);

        my $user = BOM::User->create(
            email          => 'mlt2mf@binary.com',
            password       => BOM::User::Password::hashpw('ASDF2222'),
            email_verified => 1,
        );
        $user->add_client($mf_client);
        $user->add_client($mlt_client);

        my $result = $c->call_ok(
            'document_upload',
            {
                token => $mlt_token,
                args  => {
                    document_id       => '',
                    expiration_date   => '',
                    document_type     => 'proofaddress',
                    document_format   => 'png',
                    expected_checksum => '12341412412412',
                }})->has_no_error->result;

        my $file_id = $result->{file_id};

        $result = $c->call_ok(
            'document_upload',
            {
                token => $mlt_token,
                args  => {
                    file_id => $file_id,
                    status  => 'success',
                }})->has_no_error->result;

        is $mlt_client->get_authentication('ID_DOCUMENT')->status, 'under_review', 'Authentication is under review for the client';
        is $mf_client->get_authentication('ID_DOCUMENT')->status,  'under_review', 'Authentication is under review for the sibling';
    };

    subtest 'MF to MLT' => sub {
        my $mlt_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MLT',
        });
        my $mf_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MF',
        });
        my ($mlt_token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $mlt_client->loginid);
        my ($mf_token)  = BOM::Database::Model::OAuth->new->store_access_token_only(1, $mf_client->loginid);

        my $user = BOM::User->create(
            email          => 'mf2mlt@binary.com',
            password       => BOM::User::Password::hashpw('ASDF2222'),
            email_verified => 1,
        );
        $user->add_client($mf_client);
        $user->add_client($mlt_client);

        my $result = $c->call_ok(
            'document_upload',
            {
                token => $mf_token,
                args  => {
                    document_id       => '',
                    expiration_date   => '',
                    document_type     => 'proofaddress',
                    document_format   => 'png',
                    expected_checksum => '12341412412412',
                }})->has_no_error->result;

        my $file_id = $result->{file_id};

        $result = $c->call_ok(
            'document_upload',
            {
                token => $mf_token,
                args  => {
                    file_id => $file_id,
                    status  => 'success',
                }})->has_no_error->result;

        is $mf_client->get_authentication('ID_DOCUMENT')->status,  'under_review', 'Authentication is under review for the client';
        is $mlt_client->get_authentication('ID_DOCUMENT')->status, 'under_review', 'Authentication is under review for the sibling';
    };

    subtest 'MX to MF (onfido)' => sub {
        my $status_mock = Test::MockModule->new('BOM::User::Client::Status');

        my $mx_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MLT',
        });
        my $mf_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MF',
        });
        my ($mx_token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $mx_client->loginid);
        my ($mf_token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $mf_client->loginid);

        my $user = BOM::User->create(
            email          => 'mltmmx2mfOnfido@binary.com',
            password       => BOM::User::Password::hashpw('ASDF2222'),
            email_verified => 1,
        );
        $user->add_client($mf_client);
        $user->add_client($mx_client);

        my $result = $c->call_ok(
            'document_upload',
            {
                token => $mx_token,
                args  => {
                    document_id       => '',
                    expiration_date   => '',
                    document_type     => 'proofaddress',
                    document_format   => 'png',
                    expected_checksum => '12341412412412'
                }})->has_no_error->result;

        my $file_id = $result->{file_id};

        $result = $c->call_ok(
            'document_upload',
            {
                token => $mx_token,
                args  => {
                    file_id => $file_id,
                    status  => 'success',
                }})->has_no_error->result;

        is $mx_client->get_authentication('ID_DOCUMENT')->status, 'under_review', 'Authentication is under review for the client';
        is $mf_client->get_authentication('ID_DOCUMENT')->status, 'under_review', 'Authentication is under review for the sibling';
        $status_mock->unmock_all;
    };

    subtest 'POI upload' => sub {
        my $status_mock = Test::MockModule->new('BOM::User::Client::Status');
        my $client_mock = Test::MockModule->new('BOM::User::Client');

        $client_mock->mock(
            'fully_authenticated',
            sub {
                0;
            });

        my $mx_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MX',
        });
        my $mf_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MF',
        });
        my ($mx_token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $mx_client->loginid);
        my ($mf_token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $mf_client->loginid);

        my $user = BOM::User->create(
            email          => 'docuploadpoi@binary.com',
            password       => BOM::User::Password::hashpw('ASDF2222'),
            email_verified => 1,
        );
        $user->add_client($mf_client);
        $user->add_client($mx_client);

        my $result = $c->call_ok(
            'document_upload',
            {
                token => $mx_token,
                args  => {
                    document_id              => '1618',
                    document_type            => 'passport',
                    document_format          => 'png',
                    expected_checksum        => '124124124124',
                    document_issuing_country => 'co',
                    expiration_date          => '2117-08-11',
                }})->has_no_error->result;

        my $file_id = $result->{file_id};

        $result = $c->call_ok(
            'document_upload',
            {
                token => $mx_token,
                args  => {
                    file_id => $file_id,
                    status  => 'success',
                }})->has_no_error->result;
        ok !$mx_client->get_authentication('ID_DOCUMENT'), 'POI upload does not update authentication';
        ok !$mf_client->get_authentication('ID_DOCUMENT'), 'POI upload does not update authentication';
        $status_mock->unmock_all;
        $client_mock->unmock_all;
    };

    subtest 'Fully authenticated upload' => sub {
        my $status_mock = Test::MockModule->new('BOM::User::Client::Status');
        my $client_mock = Test::MockModule->new('BOM::User::Client');

        $client_mock->mock(
            'fully_authenticated',
            sub {
                1;
            });

        my $mx_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MX',
        });
        my $mf_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MF',
        });
        my ($mx_token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $mx_client->loginid);
        my ($mf_token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $mf_client->loginid);

        my $user = BOM::User->create(
            email          => 'mx2mfFullyAuth@binary.com',
            password       => BOM::User::Password::hashpw('ASDF2222'),
            email_verified => 1,
        );
        $user->add_client($mf_client);
        $user->add_client($mx_client);

        my $result = $c->call_ok(
            'document_upload',
            {
                token => $mx_token,
                args  => {
                    document_id       => '',
                    expiration_date   => '',
                    document_type     => 'proofaddress',
                    document_format   => 'png',
                    expected_checksum => '252352362362'
                }})->has_no_error->result;

        my $file_id = $result->{file_id};

        $result = $c->call_ok(
            'document_upload',
            {
                token => $mx_token,
                args  => {
                    file_id => $file_id,
                    status  => 'success',
                }})->has_no_error->result;
        ok !$mx_client->get_authentication('ID_DOCUMENT'), 'Fully authenticated account does not update authentication';
        ok !$mf_client->get_authentication('ID_DOCUMENT'), 'Fully authenticated account does not update authentication';
        $status_mock->unmock_all;
        $client_mock->unmock_all;
    };
};

subtest 'Lifetime valid' => sub {
    my $mx_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MX',
    });
    my ($mx_token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $mx_client->loginid);

    my $user = BOM::User->create(
        email          => 'upload.lifetime@binary.com',
        password       => BOM::User::Password::hashpw('ASDF2222'),
        email_verified => 1,
    );
    $user->add_client($mx_client);

    my $result = $c->call_ok(
        'document_upload',
        {
            token => $mx_token,
            args  => {
                document_id              => '1618',
                document_type            => 'passport',
                document_issuing_country => 'co',
                document_format          => 'png',
                expected_checksum        => '124124124124',
                expiration_date          => '2099-01-01',
                lifetime_valid           => 1,
            }})->has_no_error->result;

    my $file_id = $result->{file_id};

    $c->call_ok(
        'document_upload',
        {
            token => $mx_token,
            args  => {
                file_id => $file_id,
                status  => 'success',
            }})->has_no_error->result;

    my ($document) = $mx_client->client_authentication_document;
    ok $document->lifetime_valid,   'Document uploaded is lifetime valid';
    ok !$document->expiration_date, 'Expiration date is empty';
    is $document->origin, 'client', 'Client is the origin of the document';

    subtest 'POA' => sub {
        my $mx_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MX',
        });
        my ($mx_token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $mx_client->loginid);

        my $user = BOM::User->create(
            email          => 'upload.lifetime.poa@binary.com',
            password       => BOM::User::Password::hashpw('ASDF2222'),
            email_verified => 1,
        );
        $user->add_client($mx_client);

        my $result = $c->call_ok(
            'document_upload',
            {
                token => $mx_token,
                args  => {
                    document_id       => '0990',
                    document_type     => 'utility_bill',
                    document_format   => 'png',
                    expected_checksum => '3512542',
                    expiration_date   => '2099-01-01',
                    lifetime_valid    => 1,
                }})->has_no_error->result;

        my $file_id = $result->{file_id};

        $result = $c->call_ok(
            'document_upload',
            {
                token => $mx_token,
                args  => {
                    file_id => $file_id,
                    status  => 'success',
                }})->has_no_error->result;

        my ($document) = $mx_client->client_authentication_document;
        ok $document->expiration_date, 'Expiration date set';
        ok !$document->lifetime_valid, 'POA cannot be lifetime valid';
    };
};

subtest 'Proof of ownership upload' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client->loginid);

    my $user = BOM::User->create(
        email          => 'upload.poo@binary.com',
        password       => BOM::User::Password::hashpw('ASDF2222'),
        email_verified => 1,
    );
    $user->add_client($client);

    $c->call_ok(
        'document_upload',
        {
            token => $token,
            args  => {
                document_id       => '9999',
                document_type     => 'proof_of_ownership',
                document_format   => 'png',
                expected_checksum => '3252352323',
            }}
    )->has_error->error_message_is('You must specify the proof of ownership id', 'POO id was not provided')
        ->error_code_is('UploadDenied', 'error code is correct');

    $c->call_ok(
        'document_upload',
        {
            token => $token,
            args  => {
                document_id        => '9999',
                document_type      => 'proof_of_ownership',
                document_format    => 'png',
                expected_checksum  => '3252352323',
                proof_of_ownership => {
                    id => 35235234,
                }}}
    )->has_error->error_message_is('The proof of ownership id provided is not valid', 'POO id was invalid')
        ->error_code_is('UploadDenied', 'error code is correct');

    my $poo = $client->proof_of_ownership->create({payment_service_provider => 'Skrill', trace_id => 100});

    $c->call_ok(
        'document_upload',
        {
            token => $token,
            args  => {
                document_id        => '9999',
                document_type      => 'proof_of_ownership',
                document_format    => 'png',
                expected_checksum  => '3252352323',
                proof_of_ownership => {
                    id => $poo->{id},
                }}}
    )->has_error->error_message_is('You must specify the proof of ownership details', 'POO details hashref was not provided')
        ->error_code_is('UploadDenied', 'error code is correct');

    my $result = $c->call_ok(
        'document_upload',
        {
            token => $token,
            args  => {
                document_id        => '9999',
                document_type      => 'proof_of_ownership',
                document_format    => 'png',
                expected_checksum  => '3252352323',
                proof_of_ownership => {
                    id      => $poo->{id},
                    details => {
                        some => 'thing',
                    }}}})->has_no_error->result;

    my $file_id = $result->{file_id};

    $c->call_ok(
        'document_upload',
        {
            token => $token,
            args  => {
                file_id => $file_id,
                status  => 'success',
            }})->has_no_error->result;

    my ($document) = $client->client_authentication_document;
    is $document->status,        'uploaded',           'Document uploaded';
    is $document->document_type, 'proof_of_ownership', 'Doc type is POO';
    is $document->origin,        'client',             'Client is the origin of the document';

    my $list = $client->proof_of_ownership->list();
    ($poo) = $list->@*;
    is $poo->{status}, 'uploaded', 'POO has been uploaded';

    my ($doc_id) = @{$poo->{documents}};
    is $doc_id,                                $document->id, 'POO has been bound to the document';
    is $poo->{payment_method_details}->{some}, 'thing',       'Detail succesfully attached';
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

    # Check doc is entered into databasedy

    my ($doc) = $client->find_client_authentication_document(query => [id => $result->{file_id}]);
    is($doc->document_id, $params->{args}->{document_id}, 'document is saved in db');
    is($doc->status,      'uploading',                    'document status is set to uploading');

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
    $client->status->clear_poi_poa_uploaded;
    $client->status->_clear_all;

    my $result = $c->call_ok($method, $params)->has_no_error->result;

    # Check status for copied documents from CR/MF is set for CS agents
    ok $client->status->poi_poa_uploaded, 'Status added correctly';
    is $client->status->reason('poi_poa_uploaded'), 'Documents uploaded by ' . $client->broker_code, 'Status reason added correctly';

    # Check doc is updated in database properly
    my ($doc) = $client->find_client_authentication_document(query => [id => $result->{file_id}]);
    is($doc->status, 'uploaded', 'document\'s status changed');
    ok $doc->file_name, 'Filename should not be empty';
    is $doc->checksum, $checksum, 'Checksum should be added correctly';

    my @poa_doctypes = $client->documents->poa_types->@*;
    my $is_poa       = any { $_ eq $doc->document_type } @poa_doctypes;

    # Check client status is correct
    ok($client->authentication_status eq 'under_review', 'Document should be under_review') if $is_poa and !$client->fully_authenticated;
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

subtest 'validate exp date and id' => sub {
    my @expirable     = $real_client->documents->expirable_types->@*;
    my @not_expirable = $real_client->documents->dateless_types->@*;

    for my $type (@expirable) {
        ok !BOM::RPC::v3::DocumentUpload::validate_id_and_exp_date({
                document_type   => $type,
                expiration_date => '2020-10-10',
                document_id     => '000X',
                client          => $real_client,
            }
            ),
            "$type is valid with required data passed";

        is 'missing_exp_date',
            BOM::RPC::v3::DocumentUpload::validate_id_and_exp_date({
                document_type => $type,
                document_id   => '000X',
                client        => $real_client,
            }
            ),
            "$type is invalid due to missing exp date";

        is 'missing_doc_id',
            BOM::RPC::v3::DocumentUpload::validate_id_and_exp_date({
                document_type   => $type,
                expiration_date => '2020-10-10',
                client          => $real_client,
            }
            ),
            "$type is invalid due to missing doc id";
    }

    for my $type (@not_expirable) {
        ok !BOM::RPC::v3::DocumentUpload::validate_id_and_exp_date({
                document_type => $type,
                client        => $real_client,
            }
            ),
            "$type is valid no matter what";
    }
};

subtest 'validate proof of ownership' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    my $client2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    ok !BOM::RPC::v3::DocumentUpload::validate_proof_of_ownership({
            document_type => 'driver_license',
            client        => $client,
        }
        ),
        "Driver License does not validate POO rules";

    is BOM::RPC::v3::DocumentUpload::validate_proof_of_ownership({
            document_type => 'proof_of_ownership',
            client        => $client,
        }
        ),
        'missing_proof_of_ownership_id', "Missing POO id";

    is BOM::RPC::v3::DocumentUpload::validate_proof_of_ownership({
            document_type      => 'proof_of_ownership',
            client             => $client,
            proof_of_ownership => {
                id => -1,
            }}
        ),
        'invalid_proof_of_ownership_id', "invalid POO id";

    is BOM::RPC::v3::DocumentUpload::validate_proof_of_ownership({
            document_type      => 'proof_of_ownership',
            client             => $client,
            proof_of_ownership => {
                id => 1235425235,
            }}
        ),
        'invalid_proof_of_ownership_id', "invalid POO id";

    my $poo = $client2->proof_of_ownership->create({
        payment_service_provider => 'VISA',
        trace_id                 => 100,
    });

    is BOM::RPC::v3::DocumentUpload::validate_proof_of_ownership({
            document_type      => 'proof_of_ownership',
            client             => $client,
            proof_of_ownership => {
                id => $poo->{id},
            }}
        ),
        'invalid_proof_of_ownership_id', "invalid POO id (does not belong to client)";

    is BOM::RPC::v3::DocumentUpload::validate_proof_of_ownership({
            document_type      => 'proof_of_ownership',
            client             => $client2,
            proof_of_ownership => {
                id => $poo->{id},
            }}
        ),
        'missing_proof_of_ownership_details', "missing POO details";

    is BOM::RPC::v3::DocumentUpload::validate_proof_of_ownership({
            document_type      => 'proof_of_ownership',
            client             => $client2,
            proof_of_ownership => {
                id      => $poo->{id},
                details => undef,
            }}
        ),
        'missing_proof_of_ownership_details', "missing POO details (cannot be undef)";

    ok !BOM::RPC::v3::DocumentUpload::validate_proof_of_ownership({
            document_type      => 'proof_of_ownership',
            client             => $client2,
            proof_of_ownership => {
                id      => $poo->{id},
                details => {

                },
            }}
        ),
        "valid POO upload (with empty details)";

    ok !BOM::RPC::v3::DocumentUpload::validate_proof_of_ownership({
            document_type      => 'proof_of_ownership',
            client             => $client2,
            proof_of_ownership => {
                id      => $poo->{id},
                details => {
                    name    => 'THE CAPYBARA',
                    expdate => '11/24'
                },
            }}
        ),
        "valid POO upload (with unspecific details)";
};

done_testing();
