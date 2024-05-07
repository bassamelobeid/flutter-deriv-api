use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Test::Warn;
use Test::Fatal;
use Test::MockModule;
use Test::Deep                                 qw/cmp_deeply re/;
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
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

my $emit_mock = Test::MockModule->new('BOM::Platform::Event::Emitter');
my @emissions;
$emit_mock->mock(
    'emit',
    sub {
        push @emissions, {@_};
        return undef;
    });
my $user = BOM::User->create(
    email    => $real_client->loginid . '@binary.com',
    password => 'Abcd1234'
);

$user->add_client($real_client);
$real_client->binary_user_id($user->id);
$real_client->user($user);
$real_client->save;

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

subtest 'Error for invalid expiration date in the future' => sub {
    my $custom_params = {args => {expiration_date => '3000-01-01'}};
    call_and_check_error($custom_params, 'Invalid expiration date', 'expected message for unparseable date');
};

subtest 'Error for doc invalid expiration date in the past' => sub {
    my $custom_params = {args => {expiration_date => '0111-01-01'}};
    call_and_check_error($custom_params, 'Invalid expiration date', 'expected message for unparseable date');
};

subtest 'Error for doc invalid expiration date, pure garbage' => sub {
    my $custom_params = {args => {expiration_date => 'foobar'}};
    call_and_check_error($custom_params, 'Invalid expiration date', 'expected message for unparseable date');
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
        @emissions = ();
        $file_id   = start_successful_upload($real_client);

        cmp_deeply [@emissions], [], 'no emissions';
    };

    subtest 'Finish upload and verify CS notification email is receieved' => sub {
        @emissions = ();
        finish_successful_upload($real_client, $file_id, $checksum, 1);

        cmp_deeply [@emissions],
            [{
                poi_claim_ownership => {
                    origin  => 'client',
                    file_id => re('\d+'),
                    loginid => $real_client->loginid,
                }
            },
            {
                document_upload => {
                    issuing_country => undef,
                    file_id         => re('\d+'),
                    loginid         => $real_client->loginid,
                }
            },
            {
                sync_mt5_accounts_status => {
                    binary_user_id => $real_client->binary_user_id,
                    client_loginid => $real_client->loginid,
                }}
            ],
            'expected emissions';
    };

    subtest 'Call finish again to ensure CS team is only sent 1 email' => sub {
        @emissions = ();
        finish_successful_upload($real_client, $file_id, $checksum, 0);
        cmp_deeply [@emissions],
            [{
                poi_claim_ownership => {
                    origin  => 'client',
                    file_id => re('\d+'),
                    loginid => $real_client->loginid,
                }
            },
            {
                document_upload => {
                    issuing_country => undef,
                    file_id         => re('\d+'),
                    loginid         => $real_client->loginid,
                }
            },
            {
                sync_mt5_accounts_status => {
                    binary_user_id => $real_client->binary_user_id,
                    client_loginid => $real_client->loginid,
                }}];
    };
};

#########################################################
## Tests for mandatory issuing country
#########################################################

subtest 'Attempt to upload POI document without an issuing country' => sub {
    @emissions = ();
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

subtest 'limit of uploaded documents using redis replica' => sub {
    BOM::Config::Redis::redis_replicated_write()->del('MAX_UPLOADS_KEY::' . $real_client->binary_user_id);
    BOM::Config::Redis::redis_events_write()->del('MAX_UPLOADS_KEY::' . $real_client->binary_user_id);
    limit_of_uploaded_documents_test(BOM::Config::Redis::redis_replicated_write());
};

subtest 'limit of uploaded documents using redis events' => sub {
    BOM::Config::Redis::redis_replicated_write()->del('MAX_UPLOADS_KEY::' . $real_client->binary_user_id);
    BOM::Config::Redis::redis_events_write()->del('MAX_UPLOADS_KEY::' . $real_client->binary_user_id);
    limit_of_uploaded_documents_test(BOM::Config::Redis::redis_events_write());
};

subtest 'limit of uploaded documents fallback to replicated' => sub {
    BOM::Config::Redis::redis_replicated_write()->del('MAX_UPLOADS_KEY::' . $real_client->binary_user_id);
    BOM::Config::Redis::redis_events_write()->del('MAX_UPLOADS_KEY::' . $real_client->binary_user_id);
    my $redis_mock  = Test::MockModule->new('RedisDB');
    my $get_flipper = -1;

    # the first get is from redis events
    $redis_mock->mock(
        'get',
        sub {
            $get_flipper = $get_flipper * -1;

            return undef if $get_flipper == 1;

            return $redis_mock->original('get')->(@_);
        });

    limit_of_uploaded_documents_test(BOM::Config::Redis::redis_replicated_write());

    $redis_mock->unmock_all();
};

BOM::Config::Redis::redis_replicated_write()->del('MAX_UPLOADS_KEY::' . $real_client->binary_user_id);
BOM::Config::Redis::redis_events_write()->del('MAX_UPLOADS_KEY::' . $real_client->binary_user_id);

sub limit_of_uploaded_documents_test {
    my $redis = shift;
    my $key   = 'MAX_UPLOADS_KEY::' . $real_client->binary_user_id;

    $redis->set($key, 21);

    my $error_params = +{%default_params};

    call_and_check_error($error_params, 'Maximum upload attempts per day reached. Maximum allowed is 20', 'Upload limit reached');
}

subtest 'Limit of uploaded documents reached' => sub {
    my $redis = BOM::Config::Redis::redis_replicated_write();
    my $key   = 'MAX_UPLOADS_KEY::' . $real_client->binary_user_id;

    $redis->set($key, 21);

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

    @emissions = ();
    my $file_id = start_successful_upload(
        $real_client,
        {
            args => {
                expected_checksum => 'test1111',
                document_id       => '12341234',
            }});
    finish_successful_upload($real_client, $file_id, 'test1111', 1);

    cmp_deeply [@emissions],
        [{
            poi_claim_ownership => {
                origin  => 'client',
                file_id => re('\d+'),
                loginid => $real_client->loginid,
            }
        },
        {
            document_upload => {
                issuing_country => undef,
                file_id         => re('\d+'),
                loginid         => $real_client->loginid,
            }
        },
        {
            sync_mt5_accounts_status => {
                binary_user_id => $real_client->binary_user_id,
                client_loginid => $real_client->loginid,
            }}
        ],
        'expected emissions';

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
    @emissions = ();

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

    cmp_deeply [@emissions],
        [{
            document_upload => {
                issuing_country => undef,
                file_id         => re('\d+'),
                loginid         => $client->loginid,
            }
        },
        {
            sync_mt5_accounts_status => {
                binary_user_id => $client->binary_user_id,
                client_loginid => $client->loginid,
            }}
        ],
        'expected_emissions';

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

subtest 'POA is pending' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MX',
    });
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client->loginid);

    my $user = BOM::User->create(
        email          => 'pending.poa@binary.com',
        password       => BOM::User::Password::hashpw('ASDF2222'),
        email_verified => 1,
    );
    $user->add_client($client);

    my $result = $c->call_ok(
        'document_upload',
        {
            token => $token,
            args  => {
                document_id       => '14214',
                document_type     => 'utility_bill',
                document_format   => 'png',
                expected_checksum => '235323532',
                expiration_date   => '2099-01-01',
            }})->has_no_error->result;

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
    ok $document, 'there is a document';

    $c->call_ok(
        'document_upload',
        {
            token => $token,
            args  => {
                document_id       => '14214',
                document_type     => 'utility_bill',
                document_format   => 'png',
                expected_checksum => '235323532',
                expiration_date   => '2099-01-01',
            }}
    )->has_error->error_message_is('POA document is already uploaded and pending for review', 'error message is correct')
        ->error_code_is('UploadDenied', 'error code is correct');

    is $client->get_poa_status, 'pending', 'pending POA';
    $client->set_authentication('ID_DOCUMENT', {status => 'needs_action'});
    $document->status('rejected');
    $document->save;

    $client = BOM::User::Client->new({loginid => $client->loginid});
    is $client->get_poa_status, 'rejected', 'rejected POA';
    $result = $c->call_ok(
        'document_upload',
        {
            token => $token,
            args  => {
                document_id       => '3432143',
                document_type     => 'utility_bill',
                document_format   => 'png',
                expected_checksum => '352532',
                expiration_date   => '2099-01-01',
            }})->has_no_error->result;

    $file_id = $result->{file_id};

    $c->call_ok(
        'document_upload',
        {
            token => $token,
            args  => {
                file_id => $file_id,
                status  => 'success',
            }})->has_no_error->result;

    $client = BOM::User::Client->new({loginid => $client->loginid});
    is $client->get_poa_status, 'pending', 'pending POA';

    subtest 'skip allow poa resubmission' => sub {
        $c->call_ok(
            'document_upload',
            {
                token => $token,
                args  => {
                    document_id       => '2353253',
                    document_type     => 'utility_bill',
                    document_format   => 'png',
                    expected_checksum => '2532523',
                    expiration_date   => '2099-01-01',
                }}
        )->has_error->error_message_is('POA document is already uploaded and pending for review', 'error message is correct')
            ->error_code_is('UploadDenied', 'error code is correct');

        $client->status->set('allow_poa_resubmission', 'test', 'test');

        $client = BOM::User::Client->new({loginid => $client->loginid});
        is $client->get_poa_status, 'pending', 'pending POA';
        ok $client->status->allow_poa_resubmission, 'allow POA resubmission is enabled';

        $result = $c->call_ok(
            'document_upload',
            {
                token => $token,
                args  => {
                    document_id       => '2353253',
                    document_type     => 'utility_bill',
                    document_format   => 'png',
                    expected_checksum => '2532523',
                    expiration_date   => '2099-01-01',
                }})->has_no_error->result;

        $file_id = $result->{file_id};

        $c->call_ok(
            'document_upload',
            {
                token => $token,
                args  => {
                    file_id => $file_id,
                    status  => 'success',
                }})->has_no_error;
    };
};

subtest 'POI is pending' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MX',
    });
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client->loginid);

    my $user = BOM::User->create(
        email          => 'pending.poi@binary.com',
        password       => BOM::User::Password::hashpw('ASDF2222'),
        email_verified => 1,
    );
    $user->add_client($client);

    my $result = $c->call_ok(
        'document_upload',
        {
            token => $token,
            args  => {
                document_id              => '14214',
                document_type            => 'national_identity_card',
                document_format          => 'png',
                document_issuing_country => 'co',
                expected_checksum        => '23523532',
                expiration_date          => '2099-01-01',
                page_type                => 'front',
            }})->has_no_error->result;

    my $file_id = $result->{file_id};

    $c->call_ok(
        'document_upload',
        {
            token => $token,
            args  => {
                file_id => $file_id,
                status  => 'success',
            }})->has_no_error->result;

    $result = $c->call_ok(
        'document_upload',
        {
            token => $token,
            args  => {
                document_id              => '14214',
                document_type            => 'national_identity_card',
                document_format          => 'png',
                document_issuing_country => 'co',
                expected_checksum        => '2352353255',
                expiration_date          => '2099-01-01',
                page_type                => 'back',
            }})->has_no_error->result;

    $file_id = $result->{file_id};

    $c->call_ok(
        'document_upload',
        {
            token => $token,
            args  => {
                file_id => $file_id,
                status  => 'success',
            }})->has_no_error->result;

    $result = $c->call_ok(
        'document_upload',
        {
            token => $token,
            args  => {
                document_type            => 'selfie_with_id',
                document_issuing_country => 'co',
                document_format          => 'png',
                expected_checksum        => '35345345323',
            }})->has_no_error->result;

    $file_id = $result->{file_id};

    $c->call_ok(
        'document_upload',
        {
            token => $token,
            args  => {
                file_id => $file_id,
                status  => 'success',
            }})->has_no_error->result;

    my $documents = $client->client_authentication_document;

    ok $client->documents->pending_poi_bundle(), 'there is a complete pending POI bundle';

    $c->call_ok(
        'document_upload',
        {
            token => $token,
            args  => {
                document_id              => '23532532',
                document_type            => 'passport',
                document_format          => 'png',
                document_issuing_country => 'br',
                expected_checksum        => '2365325325',
                expiration_date          => '2099-01-01',
            }}
    )->has_error->error_message_is('POI documents are already uploaded and pending for review', 'error message is correct')
        ->error_code_is('UploadDenied', 'error code is correct');

    for my $doc ($documents->@*) {
        $doc->status('rejected');
        $doc->save;
    }

    $client = BOM::User::Client->new({loginid => $client->loginid});
    ok !$client->documents->pending_poi_bundle(), 'there is no pending POI bundle';

    $result = $c->call_ok(
        'document_upload',
        {
            token => $token,
            args  => {
                document_id              => '23532532',
                document_type            => 'passport',
                document_format          => 'png',
                document_issuing_country => 'br',
                expected_checksum        => '2365325325',
                expiration_date          => '2099-01-01',
            }})->has_no_error->result;

    $file_id = $result->{file_id};

    $c->call_ok(
        'document_upload',
        {
            token => $token,
            args  => {
                file_id => $file_id,
                status  => 'success',
            }})->has_no_error->result;

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
    @emissions = ();
    my $params = {%default_params};
    $params->{args} = {%default_args};

    # Customise params
    customise_params($params, $custom_params);

    # Call and check error
    $c->call_ok($method, $params)->has_error->error_message_is($expected_err_message, $test_print_message);

    cmp_deeply [@emissions], [], 'No emissions';
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
