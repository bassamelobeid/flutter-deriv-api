use strict;
use warnings;

use Test::More;
use Log::Any::Test;
use Log::Any qw($log);
use Test::MockModule;
use Test::Deep;
use Test::Fatal;
use BOM::Platform::Context qw(request);

use Date::Utility;
use Future::Exception;
use HTTP::Response;
use JSON::MaybeUTF8 qw(encode_json_utf8 decode_json_utf8);

use BOM::Config::Redis;
use BOM::Event::Process;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);

use BOM::User::IdentityVerification;
use BOM::Event::Actions::Client::IdentityVerification;
use BOM::Database::UserDB;

use constant IDV_LOCK_PENDING => 'IDV::LOCK::PENDING::';

my $emitter_mock = Test::MockModule->new('BOM::Platform::Event::Emitter');
my @emissions;
my $emit_exception;
$emitter_mock->mock(
    'emit',
    sub {
        my ($message, $payload) = @_;

        push @emissions, +{$message => $payload};

        die $emit_exception if $emit_exception;

        return undef;
    });

my $brand              = request->brand;
my $contact_url        = $brand->contact_url({language => uc(request->language // 'en')});
my $poi_url            = $brand->authentication_url({language => uc(request->language // 'en')});
my $authentication_url = $brand->authentication_url;
my $live_chat_url      = $brand->live_chat_url({language => uc(request->language // 'en')});
my $tnc_approval_url   = $brand->tnc_approval_url({language => uc(request->language // 'en')});

my $idv_mock = Test::MockModule->new('BOM::Event::Actions::Client::IdentityVerification');
my $encoding = {};
# every execution branch of the microservice handler must use this number
# of json functions exhaustively
my $expected_json_usage = {
    encode_json_utf8 => 1,    # send data to microservice
    encode_json_text => 3,    # save some fields to the db as json objects (note that the strings should've been utf8 at this point)
};
my $expected_json_failed = {
    encode_json_utf8 => 1,    # send data to microservice
    encode_json_text => 3,    # save some fields to the db as json objects (note that the strings should've been utf8 at this point)
};
my $expected_webhook_json_usage = {
    encode_json_utf8 => 1,    # send data to microservice
    decode_json_utf8 => 1,    # receive data from the microservice
    encode_json_text => 3,    # save some fields to the db as json objects (note that the strings should've been utf8 at this point)
};

$idv_mock->mock(
    'decode_json_utf8',
    sub {
        $encoding->{'decode_json_utf8'}++;
        return $idv_mock->original('decode_json_utf8')->(@_);
    });
$idv_mock->mock(
    'encode_json_utf8',
    sub {
        $encoding->{'encode_json_utf8'}++;
        return $idv_mock->original('encode_json_utf8')->(@_);
    });
$idv_mock->mock(
    'encode_json_text',
    sub {
        $encoding->{'encode_json_text'}++;
        return $idv_mock->original('encode_json_text')->(@_);
    });

# Initiate test client
my $email = 'testw@binary.com';
my $user  = BOM::User->create(
    email          => $email,
    password       => "pwd",
    email_verified => 1,
);

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    email          => $email,
    binary_user_id => $user->id,
});
$user->add_client($client);

my ($verification_status, $personal_info_status, $personal_info, $args) = undef;
my $updates = 0;

my $mock_idv_model = Test::MockModule->new('BOM::User::IdentityVerification');
my $mock_idv_status;
$mock_idv_model->redefine(
    update_document_check => sub {
        $updates++;
        my ($idv, $args) = @_;
        $mock_idv_status = $args->{status};
        return $mock_idv_model->original('update_document_check')->(@_);
    });

my $mock_country_configs = Test::MockModule->new('Brands::Countries');
$mock_country_configs->mock(
    is_idv_supported => sub {
        my (undef, $country) = @_;

        return 0 if $country eq 'id';
        return 1;
    });

my $mock_config_service = Test::MockModule->new('BOM::Config::Services');
$mock_config_service->mock(
    config => +{
        host => 'dummy',
        port => '8080',
    });
$mock_config_service->mock(
    'is_enabled' => sub {
        if ($_[1] eq 'identity_verification') {
            return 1;
        }

        return $mock_config_service->original('is_enabled')->(@_);
    });

my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->user->id);

my $idv_event_handler = BOM::Event::Process->new(category => 'generic')->actions->{identity_verification_requested};
my $idv_proc_handler  = BOM::Event::Process->new(category => 'generic')->actions->{identity_verification_processed};

subtest 'verify identity, data is verified' => sub {
    $args = {
        loginid => $client->loginid,
    };

    $updates  = 0;
    $encoding = {};

    my $document = {
        issuing_country => 'ke',
        number          => '12345',
        type            => 'national_id',
        additional      => 'topside',
    };
    $idv_model->add_document($document);

    my $redis = BOM::Config::Redis::redis_events();
    $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 1);

    $client->address_line_1('Fake St 123');
    $client->address_line_2('apartamento 22');
    $client->address_city('fake');
    $client->address_postcode('12345900');
    $client->residence('ar');
    $client->first_name('John');
    $client->last_name('Doe');
    $client->date_of_birth('1988-02-12');
    $client->save();

    $client->status->set('poi_name_mismatch');
    $client->status->clear_age_verification;

    $verification_status  = 'Verified';
    $personal_info_status = 'Returned';
    $personal_info        = {
        FullName => 'John Doe',
        DOB      => '1988-02-12',
    };

    @emissions = ();

    ok $idv_event_handler->($args)->get, 'the event processed without error';

    # a verify process is dispatched!
    ok $idv_proc_handler->({
            id       => $client->loginid,
            status   => 'verified',
            messages => [],
            provider => {
                name         => 'smile_identity',
                dataProvider => 'true'
            },
            report => {
                full_name => $personal_info->{FullName},
                birthdate => $personal_info->{DOB},
            },
            request_body  => {request => 'sent'},
            response_body => {
                Actions => {
                    Verify_ID_Number     => $verification_status,
                    Return_Personal_Info => $personal_info_status,
                },
                $personal_info->%*,
            },
        })->get, 'the IDV response processed without error';

    cmp_deeply($encoding, $expected_json_usage, 'Expected JSON usage');

    cmp_deeply [@emissions],
        [{
            idv_verification => {
                address => {
                    postcode  => $client->address_postcode,
                    city      => $client->address_city,
                    residence => $client->residence,
                    line_1    => $client->address_line_1,
                    line_2    => $client->address_line_2,
                },
                profile => {
                    first_name => $client->first_name,
                    id         => $client->loginid,
                    birthdate  => $client->date_of_birth,
                    last_name  => $client->last_name
                },
                document => $document,
            }
        },
        {
            age_verified => {
                loginid    => $client->loginid,
                properties => {
                    website_name  => $brand->website_name,
                    live_chat_url => $live_chat_url,
                    contact_url   => $contact_url,
                    poi_url       => $poi_url,
                    email         => $client->email,
                    name          => $client->first_name
                }}
        },
        {
            sync_mt5_accounts_status => {
                client_loginid => $client->loginid,
                binary_user_id => $client->binary_user_id,
            }}
        ],
        'Expected emissions for a verified request';

    is $updates, 2, 'update document triggered twice correctly';

    ok !$client->status->poi_name_mismatch, 'poi_name_mismatch is removed correctly';
    ok $client->status->age_verification,   'age verified correctly';

    is $mock_idv_status, 'verified', 'verify_identity returns `verified` status';
};

subtest 'address verified' => sub {
    my $email = 'testzaig@binary.com';
    my $user  = BOM::User->create(
        email          => $email,
        password       => "pwd",
        email_verified => 1,
    );

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        binary_user_id => $user->id,
    });
    $client->user($user);
    $client->binary_user_id($user->id);
    $user->add_client($client);
    $client->save;

    my $args = {
        loginid => $client->loginid,
    };

    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->user->id);
    $updates  = 0;
    $encoding = {};

    my $document = {
        issuing_country => 'br',
        number          => '123.456.789-33',
        type            => 'cpf'
    };
    $idv_model->add_document($document);

    my $redis = BOM::Config::Redis::redis_events();
    $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 1);

    my $idv_document = $idv_model->get_standby_document;

    $client->address_line_1('Fake St 123');
    $client->address_line_2('apartamento 22');
    $client->address_postcode('12345900');
    $client->residence('br');
    $client->first_name('John');
    $client->last_name('Doe');
    $client->date_of_birth('1988-02-12');
    $client->save();

    $client->status->set('unwelcome',         'test', 'test');
    $client->status->set('poi_name_mismatch', 'test', 'test');
    $client->status->clear_age_verification;

    $verification_status  = 'Verified';
    $personal_info_status = 'Returned';
    $personal_info        = {
        FullName => 'John Doe',
        DOB      => '1988-02-12',
    };

    @emissions = ();
    ok $idv_event_handler->($args)->get, 'the event processed without error';

    # a verify process is dispatched!
    ok $idv_proc_handler->({
            id       => $client->loginid,
            status   => 'verified',
            provider => {
                name         => 'zaig',
                dataProvider => 'true'
            },
            messages      => ['ADDRESS_VERIFIED'],
            response_body => {},
            request_body  => {},
            report        => {},
        })->get, 'the IDV response processed without error';

    cmp_deeply($encoding, $expected_json_usage, 'Expected JSON usage');
    cmp_deeply [@emissions],
        [{
            idv_verification => {
                address => {
                    postcode  => $client->address_postcode,
                    city      => $client->address_city,
                    residence => $client->residence,
                    line_1    => $client->address_line_1,
                    line_2    => $client->address_line_2,
                },
                profile => {
                    first_name => $client->first_name,
                    id         => $client->loginid,
                    birthdate  => $client->date_of_birth,
                    last_name  => $client->last_name
                },
                document => $document,
            }
        },
        {
            age_verified => {
                loginid    => $client->loginid,
                properties => {
                    website_name  => $brand->website_name,
                    live_chat_url => $live_chat_url,
                    contact_url   => $contact_url,
                    poi_url       => $poi_url,
                    email         => $client->email,
                    name          => $client->first_name
                }}
        },
        {
            sync_mt5_accounts_status => {
                client_loginid => $client->loginid,
                binary_user_id => $client->binary_user_id,
            }}
        ],
        'Expected emissions for an address verified request';

    is $updates, 2, 'update document triggered twice correctly';

    ok !$client->status->poi_name_mismatch,                      'poi_name_mismatch is removed correctly';
    ok $client->status->age_verification,                        'age verified correctly';
    ok $client->fully_authenticated(),                           'client is fully authenticated - no mt5 lc';
    ok $client->fully_authenticated({landing_company => 'bvi'}), 'fully auth with mt5 lc';
    is $client->get_authentication('IDV_ADDRESS')->{status}, 'pass', 'IDV with address';
    ok !$client->status->unwelcome, 'client unwelcome is removed';

    is $mock_idv_status, 'verified', 'verify_identity returns `verified` status';

    my $doc = $idv_model->get_last_updated_document();

    cmp_deeply $doc->{status_messages}, encode_json_utf8(['ADDRESS_VERIFIED']), 'expected messages stored';
};

subtest 'verify_process - apply side effects' => sub {
    my $idv_proc_handler = BOM::Event::Process->new(category => 'generic')->actions->{identity_verification_processed};
    $encoding = {};

    my $email = 'test_verify_process@binary.com';
    my $user  = BOM::User->create(
        email          => $email,
        password       => "pwd123",
        email_verified => 1,
    );

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        binary_user_id => $user->id,
    });

    $client->user($user);
    $client->binary_user_id($user->id);
    $user->add_client($client);
    $client->save;

    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->user->id);
    $updates = 0;
    my $document = {
        issuing_country => 'br',
        number          => '123.456.789-33',
        type            => 'cpf'
    };
    $idv_model->add_document($document);

    $client->address_line_1('Fake St 123');
    $client->address_line_2('apartamento 22');
    $client->address_postcode('12345900');
    $client->residence('br');
    $client->first_name('John');
    $client->last_name('Doe');
    $client->date_of_birth('1988-02-12');
    $client->save();

    $client->status->set('unwelcome',         'test', 'test');
    $client->status->set('poi_name_mismatch', 'test', 'test');
    $client->status->clear_age_verification;

    $verification_status  = 'Verified';
    $personal_info_status = 'Returned';
    $personal_info        = {
        FullName => 'John Doe',
        DOB      => '1988-02-12',
    };

    my $exception = exception {
        ok $idv_proc_handler->({
                id            => $client->loginid,
                status        => 'verified',
                messages      => ['ADDRESS_VERIFIED'],
                response_body => {},
                request_body  => {},
                report        => {},
            })->get, 'the IDV response processed without error';
    };

    ok $exception =~ qr/No document check found/, 'exception thrown: no check found';

    my $idv_document = $idv_model->get_standby_document;

    $idv_model->update_document_check({
        document_id  => $idv_document->{id},
        status       => +BOM::Event::Actions::Client::IdentityVerification::IDV_DOCUMENT_STATUS->{pending},
        messages     => [+BOM::Event::Actions::Client::IdentityVerification::IDV_MESSAGES->{VERIFICATION_STARTED},],
        provider     => 'zaig',
        request_body => '{}',
    });

    @emissions = ();
    ok $idv_proc_handler->({
            id       => $client->loginid,
            status   => 'verified',
            provider => {
                name         => 'zaig',
                dataProvider => 'true'
            },
            messages      => ['ADDRESS_VERIFIED'],
            response_body => {},
            request_body  => {},
            report        => {},
        })->get, 'the IDV response processed without error';

    my $expected_json = +{$expected_json_usage->%*};
    delete $expected_json->{encode_json_utf8};    # the encode is only done at the http request, this test does not hit that event.

    cmp_deeply [@emissions],
        [{
            age_verified => {
                loginid    => $client->loginid,
                properties => {
                    website_name  => $brand->website_name,
                    live_chat_url => $live_chat_url,
                    contact_url   => $contact_url,
                    poi_url       => $poi_url,
                    email         => $client->email,
                    name          => $client->first_name
                }}
        },
        {
            sync_mt5_accounts_status => {
                client_loginid => $client->loginid,
                binary_user_id => $client->binary_user_id,
            }}
        ],
        'Expected emissions for an IDV verify process';

    cmp_deeply($encoding, $expected_json, 'Expected JSON usage');
    ok $client->status->age_verification,                        'age verified correctly';
    ok $client->fully_authenticated(),                           'client is not fully authenticated - no mt5 lc';
    ok $client->fully_authenticated({landing_company => 'bvi'}), 'fully auth with mt5 lc';
    is $client->get_authentication('IDV_ADDRESS')->{status}, 'pass', 'IDV with address';

    my $doc = $idv_model->get_last_updated_document();
    cmp_deeply $doc->{status_messages}, encode_json_utf8(['ADDRESS_VERIFIED']), 'expected messages stored';
};

subtest 'testing failed status' => sub {
    my $idv_event_handler = BOM::Event::Process->new(category => 'generic')->actions->{identity_verification_requested};
    $encoding = {};

    my $email = 'test_verify_failed@binary.com';
    my $user  = BOM::User->create(
        email          => $email,
        password       => "pwd123",
        email_verified => 1,
    );

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        binary_user_id => $user->id,
    });

    $client->user($user);
    $client->binary_user_id($user->id);
    $user->add_client($client);
    $client->save;

    my $args = {
        loginid => $client->loginid,
    };

    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->user->id);
    $updates = 0;

    my $idv_document = {
        issuing_country => 'br',
        number          => '123.456.789-33',
        type            => 'cpf'
    };
    $idv_model->add_document($idv_document);

    my $redis = BOM::Config::Redis::redis_events();
    $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 1);

    $client->address_line_1('Fake St 123');
    $client->address_line_2('apartamento 22');
    $client->address_postcode('12345900');
    $client->residence('br');
    $client->first_name('John');
    $client->last_name('Doe');
    $client->date_of_birth('1988-02-12');
    $client->save();

    @emissions = ();

    ok $idv_event_handler->($args)->get, 'the event processed without error';

    # a verify process is dispatched!
    ok $idv_proc_handler->({
            status   => 'failed',
            messages => [],
            provider => {
                name         => 'zaig',
                dataProvider => 'true'
            },
            report => {
                full_name => "John Doe",
                birthdate => '1988-02-13'
            },
            response_body => {},
            request_body  => {},
            id            => $client->loginid,
        })->get, 'the IDV response processed without error';

    my $document = $idv_model->get_last_updated_document;
    cmp_deeply($encoding, $expected_json_failed, 'Expected JSON usage');
    cmp_deeply [@emissions],
        [{
            idv_verification => {
                address => {
                    postcode  => $client->address_postcode,
                    city      => $client->address_city,
                    residence => $client->residence,
                    line_1    => $client->address_line_1,
                    line_2    => $client->address_line_2,
                },
                profile => {
                    first_name => $client->first_name,
                    id         => $client->loginid,
                    birthdate  => $client->date_of_birth,
                    last_name  => $client->last_name
                },
                document => $idv_document,
            }
        },
        {
            sync_mt5_accounts_status => {
                client_loginid => $client->loginid,
                binary_user_id => $client->binary_user_id,
            }}
        ],
        'Expected emissions for a failed IDV request';

    cmp_deeply(
        $document,
        {
            'document_number'          => '123.456.789-33',
            'status'                   => 'failed',
            'document_expiration_date' => undef,
            'is_checked'               => 1,
            'issuing_country'          => 'br',
            'status_messages'          => '[]',
            'id'                       => re('\d+'),
            'document_type'            => 'cpf'
        },
        'Document has failed status'
    );
};

subtest 'testing the exceptions verify_identity' => sub {
    my $idv_event_handler = BOM::Event::Process->new(category => 'generic')->actions->{identity_verification_requested};
    my $email             = 'test_exceptions_id@binary.com';
    my $user              = BOM::User->create(
        email          => $email,
        password       => "pwd123",
        email_verified => 1,
    );

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        binary_user_id => $user->id,
    });

    $client->user($user);
    $client->binary_user_id($user->id);
    $user->add_client($client);
    $client->save;

    my $args = {
        loginid => 'CR0',
    };
    my $error = exception {
        $idv_event_handler->($args)->get;
    };

    ok $error=~ /Could not initiate client for loginid: CR0/, 'expected exception caught bad login id here';

    $args = {
        loginid => $client->loginid,
    };

    my $redis = BOM::Config::Redis::redis_events();
    $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 1);

    $error = exception {
        $idv_event_handler->($args)->get;
    };
    ok $error=~ /No standby document found, IDV request skipped./, 'expected exception caught no documents added';

    my $bom_config_mock = Test::MockModule->new('BOM::Config::Services');
    my $idv_microservice;

    $bom_config_mock->mock(
        'is_enabled',
        sub {
            return $idv_microservice;
        });

    $idv_microservice = 0;
    $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 1);

    $error = exception {
        $idv_event_handler->($args)->get;
    };
    ok $error=~ /Could not trigger IDV, microservice is not enabled./, 'expected exception caught no idv';

    $idv_microservice = 1;

    my $idv_model_mock = Test::MockModule->new('BOM::User::IdentityVerification');

    $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 0);

    $error = exception {
        $idv_event_handler->($args)->get;
    };

    ok $error=~ /No submissions left, IDV request has ignored for loginid/, 'expected exception caught no submissions';

    $idv_model_mock->unmock_all();

};

subtest 'testing the exceptions verify_process' => sub {
    my $idv_proc_handler = BOM::Event::Process->new(category => 'generic')->actions->{identity_verification_processed};
    my $email            = 'test_exceptions@binary.com';
    my $user             = BOM::User->create(
        email          => $email,
        password       => "pwd123",
        email_verified => 1,
    );

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        binary_user_id => $user->id,
    });

    $client->user($user);
    $client->binary_user_id($user->id);
    $user->add_client($client);
    $client->save;

    my $args = {
        id => 'CR0',
    };

    my $error = exception {
        $idv_proc_handler->($args)->get;
    };

    ok $error=~ /No status received./, 'expected exception caught no status added';

    $args->{status} = 'verified';

    $error = exception {
        $idv_proc_handler->($args)->get;
    };

    ok $error=~ /Could not initiate client for loginid: CR0/, 'expected exception caught';

    $args->{id} = $client->loginid;

    $error = exception {
        $idv_proc_handler->($args)->get;
    };
    ok $error=~ /No standby document found, IDV request skipped./, 'expected exception caught no documents added';

    my $bom_config_mock = Test::MockModule->new('BOM::Config::Services');
    my $idv_microservice;

    $bom_config_mock->mock(
        'is_enabled',
        sub {
            return $idv_microservice;
        });

    $idv_microservice = 0;

    $error = exception {
        $idv_proc_handler->($args)->get;
    };
    ok $error=~ /Could not trigger IDV, microservice is not enabled./, 'expected exception caught no idv';

    $idv_microservice = 1;

    my $idv_model_mock = Test::MockModule->new('BOM::User::IdentityVerification');

    $error = exception {
        $idv_proc_handler->($args)->get;
    };

    ok $error=~ /No standby document found, IDV request skipped/, 'expected exception caught (does not check for submission left)';

    $idv_model_mock->unmock_all();

};

subtest 'testing refuted status' => sub {
    my $idv_event_handler = BOM::Event::Process->new(category => 'generic')->actions->{identity_verification_requested};

    my $email = 'test_verify_refuted@binary.com';
    my $user  = BOM::User->create(
        email          => $email,
        password       => "pwd123",
        email_verified => 1,
    );

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        binary_user_id => $user->id,
    });

    $client->user($user);
    $client->binary_user_id($user->id);
    $user->add_client($client);
    $client->save;

    my $args = {
        loginid => $client->loginid,
    };

    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->user->id);
    $updates = 0;

    my $idv_document = {
        issuing_country => 'br',
        number          => '123.456.789-33',
        type            => 'cpf'
    };
    $idv_model->add_document($idv_document);

    my $redis = BOM::Config::Redis::redis_events();
    $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 1);

    $client->address_line_1('Fake St 123');
    $client->address_line_2('apartamento 22');
    $client->address_postcode('12345900');
    $client->residence('br');
    $client->first_name('John');
    $client->last_name('Doe');
    $client->date_of_birth('1988-02-12');
    $client->save();

    @emissions = ();

    ok $idv_event_handler->($args)->get, 'the event processed without error';

    # a verify process is dispatched!
    ok $idv_proc_handler->({
            status   => 'refuted',
            messages => [],
            provider => {
                name         => 'zaig',
                dataProvider => 'true'
            },
            report        => {birthdate => "1988-02-12"},
            id            => $client->loginid,
            response_body => {},
            request_body  => {},
        })->get, 'the IDV response processed without error';

    cmp_deeply [@emissions],
        [{
            idv_verification => {
                address => {
                    postcode  => $client->address_postcode,
                    city      => $client->address_city,
                    residence => $client->residence,
                    line_1    => $client->address_line_1,
                    line_2    => $client->address_line_2,
                },
                profile => {
                    first_name => $client->first_name,
                    id         => $client->loginid,
                    birthdate  => $client->date_of_birth,
                    last_name  => $client->last_name
                },
                document => $idv_document,
            }
        },
        {
            identity_verification_rejected => {
                loginid    => $client->loginid,
                properties => {
                    authentication_url => $authentication_url,
                    live_chat_url      => $live_chat_url,
                    title              => 'We were unable to verify your document details',
                }}
        },
        {
            sync_mt5_accounts_status => {
                client_loginid => $client->loginid,
                binary_user_id => $client->binary_user_id,
            }}
        ],
        'Expected emissions for a refuted IDV request';

    my $document = $idv_model->get_last_updated_document;

    cmp_deeply(
        $document,
        {
            'document_number'          => '123.456.789-33',
            'status'                   => 'refuted',
            'document_expiration_date' => undef,
            'is_checked'               => 1,
            'issuing_country'          => 'br',
            'status_messages'          => '[]',
            'id'                       => re('\d+'),
            'document_type'            => 'cpf'
        },
        'Document has refuted status'
    );
};

subtest 'testing unavailable status' => sub {
    my $idv_event_handler = BOM::Event::Process->new(category => 'generic')->actions->{identity_verification_requested};

    my $email = 'test_verify_unavailable@binary.com';
    my $user  = BOM::User->create(
        email          => $email,
        password       => "pwd123",
        email_verified => 1,
    );

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        binary_user_id => $user->id,
    });

    $client->user($user);
    $client->binary_user_id($user->id);
    $user->add_client($client);
    $client->save;

    my $args = {
        loginid => $client->loginid,
    };

    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->user->id);
    $updates = 0;

    my $idv_document = {
        issuing_country => 'br',
        number          => '123.456.789-33',
        type            => 'cpf'
    };

    $idv_model->add_document($idv_document);

    my $redis = BOM::Config::Redis::redis_events();
    $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 1);

    $client->address_line_1('Fake St 123');
    $client->address_line_2('apartamento 22');
    $client->address_postcode('12345900');
    $client->residence('br');
    $client->first_name('John');
    $client->last_name('Doe');
    $client->date_of_birth('1988-02-12');
    $client->save();

    @emissions = ();
    ok $idv_event_handler->($args)->get, 'the event processed without error';

    # a verify process is dispatched!
    ok $idv_proc_handler->({
            status   => 'unavailable',
            messages => [],
            provider => {
                name         => 'zaig',
                dataProvider => 'true'
            },
            report        => {birthdate => "1988-02-12"},
            id            => $client->loginid,
            response_body => {},
            request_body  => {},
        })->get, 'the IDV response processed without error';

    my $document = $idv_model->get_last_updated_document;
    cmp_deeply [@emissions],
        [{
            idv_verification => {
                address => {
                    postcode  => $client->address_postcode,
                    city      => $client->address_city,
                    residence => $client->residence,
                    line_1    => $client->address_line_1,
                    line_2    => $client->address_line_2,
                },
                profile => {
                    first_name => $client->first_name,
                    id         => $client->loginid,
                    birthdate  => $client->date_of_birth,
                    last_name  => $client->last_name
                },
                document => $idv_document,
            }
        },
        {
            sync_mt5_accounts_status => {
                client_loginid => $client->loginid,
                binary_user_id => $client->binary_user_id,
            }}
        ],
        'Expected emissions for a failed IDV request';

    cmp_deeply(
        $document,
        {
            'document_number'          => '123.456.789-33',
            'status'                   => 'failed',
            'document_expiration_date' => undef,
            'is_checked'               => 1,
            'issuing_country'          => 'br',
            'status_messages'          => '[]',
            'id'                       => re('\d+'),
            'document_type'            => 'cpf'
        },
        'Document has unavailable status'
    );
};

subtest 'testing refuted status and underage in messages' => sub {
    my $idv_event_handler = BOM::Event::Process->new(category => 'generic')->actions->{identity_verification_requested};

    my $email = 'test_verify_pass+underage_message@binary.com';
    my $user  = BOM::User->create(
        email          => $email,
        password       => "pwd123",
        email_verified => 1,
    );

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        binary_user_id => $user->id,
    });

    $client->user($user);
    $client->binary_user_id($user->id);
    $user->add_client($client);
    $client->save;

    my $args = {
        loginid => $client->loginid,
    };

    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->user->id);
    $updates = 0;

    my $idv_document = {
        issuing_country => 'br',
        number          => '123.456.789-33',
        type            => 'cpf'
    };
    $idv_model->add_document($idv_document);

    my $redis = BOM::Config::Redis::redis_events();
    $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 1);

    $client->address_line_1('Fake St 123');
    $client->address_line_2('apartamento 22');
    $client->address_postcode('12345900');
    $client->residence('br');
    $client->first_name('John');
    $client->last_name('Doe');
    my $underage_date = Date::Utility->new()->minus_years(17)->date_yyyymmdd;
    $client->date_of_birth($underage_date);
    $client->save();

    @emissions = ();

    ok $idv_event_handler->($args)->get, 'the event processed without error';

    # a verify process is dispatched!
    ok $idv_proc_handler->({
            status   => 'refuted',
            messages => ['UNDERAGE'],
            provider => {
                name         => 'zaig',
                dataProvider => 'true'
            },
            report => {
                full_name => "John Doe",
                birthdate => $underage_date
            },
            response_body => {},
            request_body  => {},
            id            => $client->loginid,
        })->get, 'the IDV response processed without error';

    ok $client->status->disabled, 'Client status properly disabled due to underage';
    cmp_deeply [@emissions],
        [{
            idv_verification => {
                address => {
                    postcode  => $client->address_postcode,
                    city      => $client->address_city,
                    residence => $client->residence,
                    line_1    => $client->address_line_1,
                    line_2    => $client->address_line_2,
                },
                profile => {
                    first_name => $client->first_name,
                    id         => $client->loginid,
                    birthdate  => $client->date_of_birth,
                    last_name  => $client->last_name
                },
                document => $idv_document,
            }
        },
        {
            underage_account_closed => {
                loginid    => $client->loginid,
                properties => {
                    tnc_approval => $tnc_approval_url,
                }}
        },
        {
            identity_verification_rejected => {
                loginid    => $client->loginid,
                properties => {
                    authentication_url => $authentication_url,
                    live_chat_url      => $live_chat_url,
                    title              => 'We were unable to verify your document details',
                }}
        },
        {
            sync_mt5_accounts_status => {
                client_loginid => $client->loginid,
                binary_user_id => $client->binary_user_id,
            }}
        ],
        'Expected emissions for a refuted underage IDV request';

    my $document = $idv_model->get_last_updated_document;

    cmp_deeply(
        $document,
        {
            'document_number'          => '123.456.789-33',
            'status'                   => 'refuted',
            'document_expiration_date' => undef,
            'is_checked'               => 1,
            'issuing_country'          => 'br',
            'status_messages'          => '["UNDERAGE"]',
            'id'                       => re('\d+'),
            'document_type'            => 'cpf'
        },
        'Document has refuted from pass -  status underage'
    );

};

subtest 'testing refuted status and expired' => sub {
    my $idv_event_handler = BOM::Event::Process->new(category => 'generic')->actions->{identity_verification_requested};

    my $email = 'test_verify_refuted+expired@binary.com';
    my $user  = BOM::User->create(
        email          => $email,
        password       => "pwd123",
        email_verified => 1,
    );

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        binary_user_id => $user->id,
    });

    $client->user($user);
    $client->binary_user_id($user->id);
    $user->add_client($client);
    $client->save;

    my $args = {
        loginid => $client->loginid,
    };

    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->user->id);
    $updates = 0;
    my $current_submissions = $idv_model->submissions_left;

    my $idv_document = {
        issuing_country => 'br',
        number          => '123.456.789-33',
        type            => 'cpf',
    };
    $idv_model->add_document($idv_document);

    my $redis = BOM::Config::Redis::redis_events();
    $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 1);

    $client->address_line_1('Fake St 123');
    $client->address_line_2('apartamento 22');
    $client->address_postcode('12345900');
    $client->residence('br');
    $client->first_name('John');
    $client->last_name('Doe');
    $client->date_of_birth('2005-02-12');
    $client->save();

    @emissions = ();

    $client->status->set('age_verification', 'staff', 'age verified manually');

    ok $idv_event_handler->($args)->get, 'the event processed without error';

    # a verify process is dispatched!
    ok $idv_proc_handler->({
            status   => 'refuted',
            messages => ['EXPIRED'],
            provider => {
                name         => 'zaig',
                dataProvider => 'true'
            },
            report => {
                full_name   => "John Doe",
                birthdate   => "2005-02-12",
                expiry_date => "2009-05-12",
            },
            response_body => {},
            request_body  => {},
            id            => $client->loginid,
        })->get, 'the IDV response processed without error';

    ok !$client->status->age_verification, 'age verification was cleared';
    cmp_deeply [@emissions],
        [{
            idv_verification => {
                address => {
                    postcode  => $client->address_postcode,
                    city      => $client->address_city,
                    residence => $client->residence,
                    line_1    => $client->address_line_1,
                    line_2    => $client->address_line_2,
                },
                profile => {
                    first_name => $client->first_name,
                    id         => $client->loginid,
                    birthdate  => $client->date_of_birth,
                    last_name  => $client->last_name
                },
                document => $idv_document,
            }
        },
        {
            identity_verification_rejected => {
                loginid    => $client->loginid,
                properties => {
                    authentication_url => $authentication_url,
                    live_chat_url      => $live_chat_url,
                    title              => 'We were unable to verify your document details',
                }}
        },
        {
            sync_mt5_accounts_status => {
                client_loginid => $client->loginid,
                binary_user_id => $client->binary_user_id,
            }}
        ],
        'Expected emissions for a refuted + expired IDV request';

    my $document = $idv_model->get_last_updated_document;

    cmp_deeply(
        $document,
        {
            'document_number'          => '123.456.789-33',
            'status'                   => 'refuted',
            'document_expiration_date' => '2009-05-12 00:00:00',
            'is_checked'               => 1,
            'issuing_country'          => 'br',
            'status_messages'          => '["EXPIRED"]',
            'id'                       => re('\d+'),
            'document_type'            => 'cpf'
        },
        'Document has refuted from pass -  status expired'
    );

    # the decrease of attempts occurs before event triggering so testing that the counter did not change is enough
    is $idv_model->submissions_left, $current_submissions, 'Submission left did not change for name mismatch case';
};

subtest 'testing refuted status and dob mismatch' => sub {
    my $email = 'test_verify_refuted+dobmismatch@binary.com';
    my $user  = BOM::User->create(
        email          => $email,
        password       => "pwd123",
        email_verified => 1,
    );

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        binary_user_id => $user->id,
    });

    $client->user($user);
    $client->binary_user_id($user->id);
    $user->add_client($client);
    $client->save;

    my $args = {
        loginid => $client->loginid,
    };

    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->user->id);
    $updates = 0;
    my $current_submissions = $idv_model->submissions_left;

    my $idv_document = {
        issuing_country => 'br',
        number          => '123.456.789-33',
        type            => 'cpf',
    };
    $idv_model->add_document($idv_document);

    my $redis = BOM::Config::Redis::redis_events();
    $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 1);

    $client->address_line_1('Fake St 123');
    $client->address_line_2('apartamento 22');
    $client->address_postcode('12345900');
    $client->residence('br');
    $client->first_name('John');
    $client->last_name('Doe');
    $client->date_of_birth('1996-02-12');
    $client->save();

    @emissions = ();

    $client->status->set('age_verification', 'staff', 'age verified manually');

    ok $idv_event_handler->($args)->get, 'the event processed without error';

    # a verify process is dispatched!
    ok $idv_proc_handler->({
            status   => 'refuted',
            messages => ['DOB_MISMATCH'],
            provider => {
                name         => 'zaig',
                dataProvider => 'true'
            },
            report => {
                full_name => "John Doe",
                birthdate => "1997-03-12",
            },
            response_body => {},
            request_body  => {},
            id            => $client->loginid,
        })->get, 'the IDV response processed without error';

    ok !$client->status->age_verification, 'age verification was cleared';
    cmp_deeply [@emissions],
        [{
            idv_verification => {
                address => {
                    postcode  => $client->address_postcode,
                    city      => $client->address_city,
                    residence => $client->residence,
                    line_1    => $client->address_line_1,
                    line_2    => $client->address_line_2,
                },
                profile => {
                    first_name => $client->first_name,
                    id         => $client->loginid,
                    birthdate  => $client->date_of_birth,
                    last_name  => $client->last_name
                },
                document => $idv_document,
            }
        },
        {
            identity_verification_rejected => {
                loginid    => $client->loginid,
                properties => {
                    authentication_url => $authentication_url,
                    live_chat_url      => $live_chat_url,
                    title              => 'We were unable to verify your document details',
                }}
        },
        {
            sync_mt5_accounts_status => {
                client_loginid => $client->loginid,
                binary_user_id => $client->binary_user_id,
            }}
        ],
        'Expected emissions for a refuted + dob mismatch IDV request';

    my $document = $idv_model->get_last_updated_document;

    cmp_deeply(
        $document,
        {
            'document_number'          => '123.456.789-33',
            'status'                   => 'refuted',
            'document_expiration_date' => undef,
            'is_checked'               => 1,
            'issuing_country'          => 'br',
            'status_messages'          => '["DOB_MISMATCH"]',
            'id'                       => re('\d+'),
            'document_type'            => 'cpf'
        },
        'Document has refuted from pass -  status dob mismatch'
    );

    # the decrease of attempts occurs before event triggering so testing that the counter did not change is enough
    is $idv_model->submissions_left, $current_submissions, 'Submission left did not change for dob mismatch case';
};

subtest 'testing refuted status and name mismatch' => sub {
    my $idv_event_handler = BOM::Event::Process->new(category => 'generic')->actions->{identity_verification_requested};

    my $email = 'test_verify_refuted+namemismatch@binary.com';
    my $user  = BOM::User->create(
        email          => $email,
        password       => "pwd123",
        email_verified => 1,
    );

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        binary_user_id => $user->id,
    });

    $client->user($user);
    $client->binary_user_id($user->id);
    $user->add_client($client);
    $client->save;

    my $args = {
        loginid => $client->loginid,
    };

    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->user->id);
    $updates = 0;
    my $current_submissions = $idv_model->submissions_left;

    my $idv_document = {
        issuing_country => 'br',
        number          => '123.456.789-33',
        type            => 'cpf',
    };
    $idv_model->add_document($idv_document);

    my $redis = BOM::Config::Redis::redis_events();
    $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 1);

    $client->address_line_1('Fake St 123');
    $client->address_line_2('apartamento 22');
    $client->address_postcode('12345900');
    $client->residence('br');
    $client->first_name('John');
    $client->last_name('Doe');
    $client->date_of_birth('1996-02-12');
    $client->save();

    @emissions = ();

    ok $idv_event_handler->($args)->get, 'the event processed without error';

    # a verify process is dispatched!
    ok $idv_proc_handler->({
            status   => 'refuted',
            messages => ['NAME_MISMATCH'],
            provider => {
                name         => 'zaig',
                dataProvider => 'true'
            },
            report => {
                full_name => "John Mary Doe",
            },
            response_body => {},
            request_body  => {},
            id            => $client->loginid,
        })->get, 'the IDV response processed without error';

    ok $client->status->poi_name_mismatch, 'POI name mismatch status applied properly';
    cmp_deeply [@emissions],
        [{
            idv_verification => {
                address => {
                    postcode  => $client->address_postcode,
                    city      => $client->address_city,
                    residence => $client->residence,
                    line_1    => $client->address_line_1,
                    line_2    => $client->address_line_2,
                },
                profile => {
                    first_name => $client->first_name,
                    id         => $client->loginid,
                    birthdate  => $client->date_of_birth,
                    last_name  => $client->last_name
                },
                document => $idv_document,
            }
        },
        {
            identity_verification_rejected => {
                loginid    => $client->loginid,
                properties => {
                    authentication_url => $authentication_url,
                    live_chat_url      => $live_chat_url,
                    title              => 'We were unable to verify your document details',
                }}
        },
        {
            sync_mt5_accounts_status => {
                client_loginid => $client->loginid,
                binary_user_id => $client->binary_user_id,
            }}
        ],
        'Expected emissions for a refuted + name mismatch IDV request';

    my $document = $idv_model->get_last_updated_document;

    cmp_deeply(
        $document,
        {
            'document_number'          => '123.456.789-33',
            'status'                   => 'refuted',
            'document_expiration_date' => undef,
            'is_checked'               => 1,
            'issuing_country'          => 'br',
            'status_messages'          => '["NAME_MISMATCH"]',
            'id'                       => re('\d+'),
            'document_type'            => 'cpf'
        },
        'Document has refuted from pass -  status name mismatch'
    );

    # the decrease of attempts occurs before event triggering so testing that the counter did not change is enough
    is $idv_model->submissions_left, $current_submissions, 'Submission left did not change for name mismatch case';
};

subtest 'pictures collected from IDV' => sub {
    for my $what (qw/selfie document/) {
        subtest "testing $what being sent as paramter - refuted" => sub {
            my $idv_event_handler = BOM::Event::Process->new(category => 'generic')->actions->{identity_verification_requested};

            my $email = "test_refuted_photo$what\@binary.com";
            my $user  = BOM::User->create(
                email          => $email,
                password       => "pwd123",
                email_verified => 1,
            );

            my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code    => 'CR',
                email          => $email,
                binary_user_id => $user->id,
            });

            $client->user($user);
            $client->binary_user_id($user->id);
            $user->add_client($client);
            $client->save;

            my $args = {
                loginid => $client->loginid,
            };

            my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->user->id);
            $updates = 0;

            my $idv_document = {
                issuing_country => 'br',
                number          => '123.456.789-33',
                type            => 'cpf',
            };
            $idv_model->add_document($idv_document);

            my $redis = BOM::Config::Redis::redis_events();
            $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 1);

            my $services_track_mock = Test::MockModule->new('BOM::Event::Services::Track');
            my $track_args;

            $services_track_mock->mock(
                'document_upload',
                sub {
                    $track_args = shift;
                    return Future->done(1);
                });

            my $s3_client_mock = Test::MockModule->new('BOM::Platform::S3Client');
            $s3_client_mock->mock(
                'upload_binary',
                sub {
                    return Future->done(1);
                });

            $client->address_line_1('Fake St 123');
            $client->address_line_2('apartamento 22');
            $client->address_postcode('12345900');
            $client->residence('br');
            $client->first_name('John');
            $client->last_name('Doe');
            $client->date_of_birth('1996-02-12');
            $client->save();

            @emissions = ();

            ok $idv_event_handler->($args)->get, 'the event processed without error';

            # a verify process is dispatched!
            ok $idv_proc_handler->({
                    status   => 'refuted',
                    messages => ['NAME_MISMATCH'],
                    provider => {
                        name         => 'zaig',
                        dataProvider => 'true'
                    },
                    report => {
                        full_name => "John Mary Doe",
                        $what     => "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==",
                    },
                    response_body => {},
                    request_body  => {},
                    id            => $client->loginid,
                })->get, 'the IDV response processed without error';

            my $document = $idv_model->get_last_updated_document;

            my $dbic = BOM::Database::UserDB::rose_db(operation => 'replica')->dbic;

            my $check = $dbic->run(
                fixup => sub {
                    $_->selectall_arrayref("SELECT photo_id FROM idv.document_check where document_id = ?", {Slice => {}}, $document->{id});
                });

            cmp_deeply $check , [{photo_id => [re('\d+')]}], 'photo id returned is non null';
            is $track_args->{loginid}, $client->loginid, 'Correct loginid sent';

            cmp_deeply(
                $track_args->{properties},
                {
                    'upload_date'     => re('.*'),
                    'file_name'       => re('.*'),
                    'id'              => re('.*'),
                    'lifetime_valid'  => re('.*'),
                    'document_id'     => '',
                    'comments'        => '',
                    'expiration_date' => undef,
                    'document_type'   => 'photo'
                },
                'Document info was populated correctly'
            );

            $document = $idv_model->get_last_updated_document;

            cmp_deeply(
                $document,
                {
                    'document_number'          => '123.456.789-33',
                    'status'                   => 'refuted',
                    'document_expiration_date' => undef,
                    'is_checked'               => 1,
                    'issuing_country'          => 'br',
                    'status_messages'          => '["NAME_MISMATCH"]',
                    'id'                       => re('\d+'),
                    'document_type'            => 'cpf'
                },
                'Document has refuted from pass'
            );

            cmp_deeply [@emissions],
                [{
                    idv_verification => {
                        address => {
                            postcode  => $client->address_postcode,
                            city      => $client->address_city,
                            residence => $client->residence,
                            line_1    => $client->address_line_1,
                            line_2    => $client->address_line_2,
                        },
                        profile => {
                            first_name => $client->first_name,
                            id         => $client->loginid,
                            birthdate  => $client->date_of_birth,
                            last_name  => $client->last_name
                        },
                        document => $idv_document,
                    }
                },
                {
                    identity_verification_rejected => {
                        loginid    => $client->loginid,
                        properties => {
                            authentication_url => $authentication_url,
                            live_chat_url      => $live_chat_url,
                            title              => 'We were unable to verify your document details',
                        }}
                },
                {
                    sync_mt5_accounts_status => {
                        client_loginid => $client->loginid,
                        binary_user_id => $client->binary_user_id,
                    }}
                ],
                'Expected emissions for a refuted + name mismatch IDV request';

            my ($photo) = $check->@*;

            my ($doc) = $client->find_client_authentication_document(query => [id => $photo->{photo_id}]);

            is $doc->{status},          'rejected', 'status in BO reflects idv status - rejected';
            is $doc->{issuing_country}, 'br',       'issuing country is correctly populated';
        };

        subtest "testing $what being sent as paramter - verified" => sub {
            my $idv_event_handler = BOM::Event::Process->new(category => 'generic')->actions->{identity_verification_requested};

            my $email = "test_verify_photo$what\@binary.com";
            my $user  = BOM::User->create(
                email          => $email,
                password       => "pwd123",
                email_verified => 1,
            );

            my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code    => 'CR',
                email          => $email,
                binary_user_id => $user->id,
            });

            $client->user($user);
            $client->binary_user_id($user->id);
            $user->add_client($client);
            $client->save;

            my $args = {
                loginid => $client->loginid,
            };

            my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->user->id);
            $updates = 0;

            my $idv_document = {
                issuing_country => 'br',
                number          => '123.456.789-33',
                type            => 'cpf',
            };
            $idv_model->add_document($idv_document);

            my $redis = BOM::Config::Redis::redis_events();
            $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 1);

            my $services_track_mock = Test::MockModule->new('BOM::Event::Services::Track');
            my $track_args;

            $services_track_mock->mock(
                'document_upload',
                sub {
                    $track_args = shift;
                    return Future->done(1);
                });

            my $s3_client_mock = Test::MockModule->new('BOM::Platform::S3Client');
            $s3_client_mock->mock(
                'upload_binary',
                sub {
                    return Future->done(1);
                });

            $client->address_line_1('Fake St 123');
            $client->address_line_2('apartamento 22');
            $client->address_postcode('12345900');
            $client->residence('br');
            $client->first_name('John');
            $client->last_name('Doe');
            $client->date_of_birth('1996-02-12');
            $client->save();

            @emissions = ();

            ok $idv_event_handler->($args)->get, 'the event processed without error';

            # a verify process is dispatched!
            ok $idv_proc_handler->({
                    status   => 'verified',
                    messages => ['NAME_MISMATCH'],
                    provider => {
                        name         => 'zaig',
                        dataProvider => 'true'
                    },
                    report => {
                        full_name => "John Mary Doe",
                        $what     => "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==",
                    },
                    response_body => {},
                    request_body  => {},
                    id            => $client->loginid,
                })->get, 'the IDV response processed without error';

            my $document = $idv_model->get_last_updated_document;

            my $dbic = BOM::Database::UserDB::rose_db(operation => 'replica')->dbic;

            my $check = $dbic->run(
                fixup => sub {
                    $_->selectall_arrayref("SELECT photo_id FROM idv.document_check where document_id = ?", {Slice => {}}, $document->{id});
                });

            cmp_deeply $check , [{photo_id => [re('\d+')]}], 'photo id returned is non null';

            cmp_deeply(
                $track_args->{properties},
                {
                    'upload_date'     => re('.*'),
                    'file_name'       => re('.*'),
                    'id'              => re('.*'),
                    'lifetime_valid'  => re('.*'),
                    'document_id'     => '',
                    'comments'        => '',
                    'expiration_date' => undef,
                    'document_type'   => 'photo'
                },
                'Document info was populated correctly'
            );

            $document = $idv_model->get_last_updated_document;

            cmp_deeply(
                $document,
                {
                    'document_number'          => '123.456.789-33',
                    'status'                   => 'verified',
                    'document_expiration_date' => undef,
                    'is_checked'               => 1,
                    'issuing_country'          => 'br',
                    'status_messages'          => '["NAME_MISMATCH"]',
                    'id'                       => re('\d+'),
                    'document_type'            => 'cpf'
                },
                'Document has verified from pass'
            );

            cmp_deeply [@emissions],
                [{
                    idv_verification => {
                        address => {
                            postcode  => $client->address_postcode,
                            city      => $client->address_city,
                            residence => $client->residence,
                            line_1    => $client->address_line_1,
                            line_2    => $client->address_line_2,
                        },
                        profile => {
                            first_name => $client->first_name,
                            id         => $client->loginid,
                            birthdate  => $client->date_of_birth,
                            last_name  => $client->last_name
                        },
                        document => $idv_document,
                    }
                },
                {
                    age_verified => {
                        loginid    => $client->loginid,
                        properties => {
                            website_name  => $brand->website_name,
                            live_chat_url => $live_chat_url,
                            contact_url   => $contact_url,
                            poi_url       => $poi_url,
                            email         => $client->email,
                            name          => $client->first_name
                        }}
                },
                {
                    sync_mt5_accounts_status => {
                        client_loginid => $client->loginid,
                        binary_user_id => $client->binary_user_id,
                    }}
                ],
                'Expected emissions for a verified IDV request';

            $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 1);
            $idv_document = {
                issuing_country => 'br',
                number          => '123.456.789-34',
                type            => 'cpf',
            };
            $idv_model->add_document($idv_document);

            @emissions = ();
            ok $idv_event_handler->($args)->get, 'the event processed without error';

            cmp_deeply [@emissions],
                [{
                    idv_verification => {
                        address => {
                            postcode  => $client->address_postcode,
                            city      => $client->address_city,
                            residence => $client->residence,
                            line_1    => $client->address_line_1,
                            line_2    => $client->address_line_2,
                        },
                        profile => {
                            first_name => $client->first_name,
                            id         => $client->loginid,
                            birthdate  => $client->date_of_birth,
                            last_name  => $client->last_name
                        },
                        document => $idv_document,
                    }}
                ],
                'expected emissions when the callback is not yet received';

            my $check_two = $dbic->run(
                fixup => sub {
                    $_->selectall_arrayref("SELECT photo_id FROM idv.document_check where document_id = ?", {Slice => {}}, $document->{id});
                });

            cmp_deeply $check , $check_two, 'photo id returned is the same';

            my ($photo) = $check->@*;

            my ($doc) = $client->find_client_authentication_document(query => [id => $photo->{photo_id}]);

            is $doc->{status},          'verified', 'status in BO reflects idv status - verified';
            is $doc->{origin},          'idv',      'IDV is the origin of the doc';
            is $doc->{issuing_country}, 'br',       'issuing country is correctly populated';
        };
    }

    subtest "selfie & document are provided" => sub {
        my $idv_event_handler = BOM::Event::Process->new(category => 'generic')->actions->{identity_verification_requested};

        my $email = "test_verify_photoboth\@binary.com";
        my $user  = BOM::User->create(
            email          => $email,
            password       => "pwd123",
            email_verified => 1,
        );

        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code    => 'CR',
            email          => $email,
            binary_user_id => $user->id,
        });

        $client->user($user);
        $client->binary_user_id($user->id);
        $user->add_client($client);
        $client->save;

        my $args = {
            loginid => $client->loginid,
        };

        my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->user->id);
        $updates = 0;

        my $idv_document = {
            issuing_country => 'br',
            number          => '123.456.789-33',
            type            => 'cpf',
        };
        $idv_model->add_document($idv_document);

        my $redis = BOM::Config::Redis::redis_events();
        $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 1);

        my $services_track_mock = Test::MockModule->new('BOM::Event::Services::Track');
        my $track_args          = [];

        $services_track_mock->mock(
            'document_upload',
            sub {
                push $track_args->@*, shift;
                return Future->done(1);
            });

        my $s3_client_mock = Test::MockModule->new('BOM::Platform::S3Client');
        $s3_client_mock->mock(
            'upload_binary',
            sub {
                return Future->done(1);
            });

        $client->address_line_1('Fake St 123');
        $client->address_line_2('apartamento 22');
        $client->address_postcode('12345900');
        $client->residence('br');
        $client->first_name('John');
        $client->last_name('Doe');
        $client->date_of_birth('1996-02-12');
        $client->save();

        @emissions = ();

        ok $idv_event_handler->($args)->get, 'the event processed without error';

        # a verify process is dispatched!
        ok $idv_proc_handler->({
                status   => 'verified',
                messages => ['NAME_MISMATCH'],
                provider => {
                    name         => 'zaig',
                    dataProvider => 'true'
                },
                report => {
                    full_name => "John Mary Doe",
                    selfie    => 'iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAAD0lEQVR42mNk+P+/ngEIAA+AAn9nd0gSAAAAAElFTkSuQmCC',
                    document  => "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==",
                },
                response_body => {},
                request_body  => {},
                id            => $client->loginid,
            })->get, 'the IDV response processed without error';

        my $document = $idv_model->get_last_updated_document;

        my $dbic = BOM::Database::UserDB::rose_db(operation => 'replica')->dbic;

        my $check = $dbic->run(
            fixup => sub {
                $_->selectall_arrayref("SELECT photo_id FROM idv.document_check where document_id = ?", {Slice => {}}, $document->{id});
            });

        cmp_deeply $check , [{photo_id => [re('\d+'), re('\d+')]}], 'photo id returned is non null (2 ids)';

        cmp_deeply(
            [map { $_->{properties} } $track_args->@*],
            [{
                    'upload_date'     => re('.*'),
                    'file_name'       => re('.*'),
                    'id'              => re('.*'),
                    'lifetime_valid'  => re('.*'),
                    'document_id'     => '',
                    'comments'        => '',
                    'expiration_date' => undef,
                    'document_type'   => 'photo'
                },
                {
                    'upload_date'     => re('.*'),
                    'file_name'       => re('.*'),
                    'id'              => re('.*'),
                    'lifetime_valid'  => re('.*'),
                    'document_id'     => '',
                    'comments'        => '',
                    'expiration_date' => undef,
                    'document_type'   => 'photo'
                }
            ],
            'Document info was populated correctly'
        );

        $document = $idv_model->get_last_updated_document;

        cmp_deeply(
            $document,
            {
                'document_number'          => '123.456.789-33',
                'status'                   => 'verified',
                'document_expiration_date' => undef,
                'is_checked'               => 1,
                'issuing_country'          => 'br',
                'status_messages'          => '["NAME_MISMATCH"]',
                'id'                       => re('\d+'),
                'document_type'            => 'cpf'
            },
            'Document has verified from pass'
        );

        cmp_deeply [@emissions],
            [{
                idv_verification => {
                    address => {
                        postcode  => $client->address_postcode,
                        city      => $client->address_city,
                        residence => $client->residence,
                        line_1    => $client->address_line_1,
                        line_2    => $client->address_line_2,
                    },
                    profile => {
                        first_name => $client->first_name,
                        id         => $client->loginid,
                        birthdate  => $client->date_of_birth,
                        last_name  => $client->last_name
                    },
                    document => $idv_document,
                }
            },
            {
                age_verified => {
                    loginid    => $client->loginid,
                    properties => {
                        website_name  => $brand->website_name,
                        live_chat_url => $live_chat_url,
                        contact_url   => $contact_url,
                        poi_url       => $poi_url,
                        email         => $client->email,
                        name          => $client->first_name
                    }}
            },
            {
                sync_mt5_accounts_status => {
                    client_loginid => $client->loginid,
                    binary_user_id => $client->binary_user_id,
                }}
            ],
            'Expected emissions for a verified IDV request';

        $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 1);
        $idv_document = {
            issuing_country => 'br',
            number          => '123.456.789-34',
            type            => 'cpf',
        };
        $idv_model->add_document($idv_document);

        @emissions = ();
        ok $idv_event_handler->($args)->get, 'the event processed without error';

        cmp_deeply [@emissions],
            [{
                idv_verification => {
                    address => {
                        postcode  => $client->address_postcode,
                        city      => $client->address_city,
                        residence => $client->residence,
                        line_1    => $client->address_line_1,
                        line_2    => $client->address_line_2,
                    },
                    profile => {
                        first_name => $client->first_name,
                        id         => $client->loginid,
                        birthdate  => $client->date_of_birth,
                        last_name  => $client->last_name
                    },
                    document => $idv_document,
                }}
            ],
            'expected emissions when the callback is not yet received';

        my $check_two = $dbic->run(
            fixup => sub {
                $_->selectall_arrayref("SELECT photo_id FROM idv.document_check where document_id = ?", {Slice => {}}, $document->{id});
            });

        cmp_deeply $check , $check_two, 'photo id returned is the same';

        my ($photo) = $check->@*;

        my ($doc1, $doc2) = $client->find_client_authentication_document(query => [id => $photo->{photo_id}]);

        is $doc1->{status},          'verified', 'status in BO reflects idv status - verified';
        is $doc1->{origin},          'idv',      'IDV is the origin of the doc';
        is $doc1->{issuing_country}, 'br',       'issuing country is correctly popualted';

        is $client->authentication_status, 'idv_photo', 'Auth status is idv photo';
        ok $client->fully_authenticated,                             'Fully auth - no mt5 lc';
        ok $client->fully_authenticated({landing_company => 'bvi'}), 'fully auth with mt5 lc';

        $client->aml_risk_classification('high');
        $client->save;
        ok !$client->fully_authenticated, 'Not Fully auth';
        is $client->get_authentication('IDV_PHOTO')->{status}, 'pass',     'IDV + Photo';
        is $doc2->{status},                                    'verified', 'status in BO reflects idv status - verified';
        is $doc2->{origin},                                    'idv',      'IDV is the origin of the doc';
        is $doc2->{issuing_country},                           'br',       'issuing country is correctly popualted';
    };
};

subtest 'testing callback status' => sub {
    my $idv_proc_handler = BOM::Event::Process->new(category => 'generic')->actions->{identity_verification_processed};

    my $email = 'test_callback_status@binary.com';
    my $user  = BOM::User->create(
        email          => $email,
        password       => "pwd123",
        email_verified => 1,
    );

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        binary_user_id => $user->id,
    });

    $client->user($user);
    $client->binary_user_id($user->id);
    $user->add_client($client);
    $client->save;

    my $args = {
        id       => $client->loginid,
        status   => 'callback',
        provider => {
            name         => 'metamap',
            dataProvider => 'true'
        },
        response => {},
        message  => [],
    };

    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->user->id);
    $updates = 0;
    my $idv_document = {
        issuing_country => 'br',
        number          => '123.456.789-99',
        type            => 'cpf'
    };
    $idv_model->add_document($idv_document);

    $client->address_line_1('Fake St 123');
    $client->address_line_2('apartamento 22');
    $client->address_postcode('12345900');
    $client->residence('br');
    $client->first_name('John');
    $client->last_name('Doe');
    $client->date_of_birth('1988-02-12');
    $client->save();

    my $exception = exception {
        ok $idv_proc_handler->({
                id            => $client->loginid,
                status        => 'verified',
                messages      => ['ADDRESS_VERIFIED'],
                response_body => {},
                request_body  => {},
                report        => {},
            })->get, 'the IDV response processed without error';
    };

    ok $exception =~ qr/No document check found/, 'exception thrown: no check found';

    my $idv_document_model = $idv_model->get_standby_document;

    $idv_model->update_document_check({
        document_id  => $idv_document_model->{id},
        status       => +BOM::Event::Actions::Client::IdentityVerification::IDV_DOCUMENT_STATUS->{pending},
        messages     => [+BOM::Event::Actions::Client::IdentityVerification::IDV_MESSAGES->{VERIFICATION_STARTED},],
        provider     => 'zaig',
        request_body => '{}',
    });

    @emissions = ();
    ok $idv_proc_handler->($args)->get, 'the event processed without error';

    cmp_deeply [@emissions],
        [{
            sync_mt5_accounts_status => {
                client_loginid => $client->loginid,
                binary_user_id => $client->binary_user_id,
            }}
        ],
        'Expected emissions after callback';

    my $document = $idv_model->get_last_updated_document;

    cmp_deeply(
        $document,
        {
            'document_number'          => '123.456.789-99',
            'status'                   => 'deferred',
            'document_expiration_date' => undef,
            'is_checked'               => 1,
            'issuing_country'          => 'br',
            'status_messages'          => '[]',
            'id'                       => $document->{id},
            'document_type'            => 'cpf'
        },
        'Callback status is deferred'
    );
};

subtest 'testing unexpected error' => sub {
    my $idv_event_handler = BOM::Event::Process->new(category => 'generic')->actions->{identity_verification_requested};

    my $email = 'test_verify_unexpected_error@binary.com';
    my $user  = BOM::User->create(
        email          => $email,
        password       => "pwd123",
        email_verified => 1,
    );

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        binary_user_id => $user->id,
    });

    $client->user($user);
    $client->binary_user_id($user->id);
    $user->add_client($client);
    $client->save;

    my $args = {
        loginid => $client->loginid,
    };

    my $redis = BOM::Config::Redis::redis_events();

    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->user->id);
    $updates = 0;
    my $idv_document = {
        issuing_country => 'br',
        number          => '123.456.789-33',
        type            => 'cpf'
    };
    $idv_model->add_document($idv_document);

    $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 1);

    $client->address_line_1('Fake St 123');
    $client->address_line_2('apartamento 22');
    $client->address_postcode('12345900');
    $client->residence('br');
    $client->first_name('John');
    $client->last_name('Doe');
    $client->date_of_birth('1988-02-12');
    $client->save();

    $emit_exception = 'fatal failure';
    @emissions      = ();
    ok $idv_event_handler->($args)->get, 'the event processed without error';
    $emit_exception = undef;

    cmp_deeply [@emissions],
        [{
            idv_verification => {
                address => {
                    postcode  => $client->address_postcode,
                    city      => $client->address_city,
                    residence => $client->residence,
                    line_1    => $client->address_line_1,
                    line_2    => $client->address_line_2,
                },
                profile => {
                    first_name => $client->first_name,
                    id         => $client->loginid,
                    birthdate  => $client->date_of_birth,
                    last_name  => $client->last_name
                },
                document => $idv_document,
            },
        }
        ],
        'expected emissions for an unexpected error while performing the IDV request';
    my $document = $idv_model->get_last_updated_document;

    cmp_deeply(
        $document,
        {
            'document_number'          => '123.456.789-33',
            'status'                   => 'failed',
            'document_expiration_date' => undef,
            'is_checked'               => 1,
            'issuing_country'          => 'br',
            'status_messages'          => '["UNAVAILABLE_MICROSERVICE"]',
            'id'                       => re('\d+'),
            'document_type'            => 'cpf'
        },
        'Document has unavailable status'
    );

    $log->contains_ok(qr/due to fatal failure/, "good message was logged");

};

subtest 'unit test - idv_webhook_relay' => sub {
    my $idv_event_handler = BOM::Event::Process->new(category => 'generic')->actions->{idv_webhook_received};

    subtest 'Callback' => sub {
        @emissions = ();

        BOM::Event::Actions::Client::IdentityVerification::idv_webhook_relay({
                data    => {body           => {test => 1}},
                headers => {'x-request-id' => '1234'}})->get;

        cmp_deeply [@emissions],
            [{
                idv_webhook => {
                    body    => {test           => '1'},
                    headers => {'x-request-id' => '1234'}}}
            ],
            'expected emissions, monolith simply forwards the request for the microservice to resolve';
    };
};

subtest 'integration test - webhook' => sub {
    my $email = 'integrates+webhook+idv@binary.com';
    my $user  = BOM::User->create(
        email          => $email,
        password       => "pwd123",
        email_verified => 1,
    );

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        binary_user_id => $user->id,
    });

    $client->user($user);
    $client->binary_user_id($user->id);
    $user->add_client($client);
    $client->save;

    my $args = {
        loginid => $client->loginid,
    };

    my $redis = BOM::Config::Redis::redis_events();

    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->user->id);
    $updates = 0;
    $idv_model->add_document({
        issuing_country => 'ar',
        number          => '111111222',
        type            => 'dni'
    });

    $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 1);

    $client->address_line_1('Street');
    $client->address_postcode('123');
    $client->residence('ar');
    $client->first_name('dev');
    $client->last_name('test');
    $client->date_of_birth('1990-01-01');
    $client->save();

    my $dog_mock = Test::MockModule->new('DataDog::DogStatsd::Helper');
    my @doggy_bag;

    $dog_mock->mock(
        'stats_inc',
        sub {
            push @doggy_bag, shift;
        });

    subtest 'MetaMap callback' => sub {
        $log->clear();

        my $idv_response = {
            report => {
                birthdate => '2000-01-24',
                full_name => 'NOT THE ONE YOU ARE LOOKING FOR'
            },
            'provider' => {
                'name'         => 'metamap',
                'dataProvider' => 'true'
            },
            'request_body' => {
                'body' => {
                    'documentNumber' => '111111222',
                    'callbackUrl'    => 'https://qaXX.deriv.dev/idv'
                },
                url => '/govchecks/v1/ar/renaper'
            },
            response_body => {
                error => undef,
                data  => {
                    taxIdNumber         => '111',
                    dateOfBirth         => '2000-01-24',
                    dniNumber           => '111111222',
                    activityDescription => '-',
                    fullName            => 'Not the one you are looking for',
                    activityCode        => '-',
                    phoneNumbers        => ['-'],
                    taxIdType           => 'CUIL',
                    deceased            => 0,
                    cuit                => '111'
                }
            },
            messages => ['NAME_MISMATCH', 'DOB_MISMATCH'],
            status   => 'refuted',
            id       => $client->loginid,
        };

        my $exception = exception {
            ok $idv_proc_handler->({
                    id            => $client->loginid,
                    status        => 'verified',
                    messages      => ['ADDRESS_VERIFIED'],
                    response_body => {},
                    request_body  => {},
                    report        => {},
                })->get, 'the IDV response processed without error';
        };

        ok $exception =~ qr/No document check found/, 'exception thrown: no check found';

        my $idv_document = $idv_model->get_standby_document;

        $idv_model->update_document_check({
            document_id  => $idv_document->{id},
            status       => +BOM::Event::Actions::Client::IdentityVerification::IDV_DOCUMENT_STATUS->{pending},
            messages     => [+BOM::Event::Actions::Client::IdentityVerification::IDV_MESSAGES->{VERIFICATION_STARTED},],
            provider     => 'zaig',
            request_body => '{}',
        });

        @emissions = ();
        my $data = BOM::Event::Actions::Client::IdentityVerification::idv_webhook_relay({
                data => {
                    body => {
                        test => 1,
                    }
                },
                headers => {'x-request-id' => '1234'}})->get;

        # a verify process is dispatched!
        ok $idv_proc_handler->($idv_response)->get, 'the IDV response processed without error';

        cmp_deeply [@emissions],
            [{
                idv_webhook => {
                    body => {
                        test => 1,
                    },
                    headers => {'x-request-id' => '1234'},
                }
            },
            {
                identity_verification_rejected => {
                    loginid    => $client->loginid,
                    properties => {
                        authentication_url => $authentication_url,
                        live_chat_url      => $live_chat_url,
                        title              => 'We were unable to verify your document details',
                    }}
            },
            {
                sync_mt5_accounts_status => {
                    client_loginid => $client->loginid,
                    binary_user_id => $client->binary_user_id,
                }}
            ],
            'Expected emissions for a refuted IDV webhook request';

        my $last_doc = $idv_model->get_last_updated_document();
        my $check    = $idv_model->get_document_check_detail($last_doc->{id});
        is $last_doc->{status}, 'refuted', 'Expected status';
        cmp_deeply decode_json_utf8($last_doc->{status_messages}), ['NAME_MISMATCH', 'DOB_MISMATCH'], 'expected status messages';

        cmp_deeply decode_json_utf8($check->{request}),  $idv_response->{request_body},  'expected request body';
        cmp_deeply decode_json_utf8($check->{response}), $idv_response->{response_body}, 'expected response body';
        cmp_deeply decode_json_utf8($check->{report}),   $idv_response->{report},        'expected check report';
        cmp_deeply [@doggy_bag],                         [],                             'Expected dog bag';

        $log->clear();
        @doggy_bag = ();
    };
    $dog_mock->unmock_all();

};

subtest 'testing _detect_mime_type' => sub {
    my $result;

    $result = BOM::Event::Actions::Client::IdentityVerification::_detect_mime_type('test');

    is $result, undef, 'base case returns properly';

    $result = BOM::Event::Actions::Client::IdentityVerification::_detect_mime_type(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');

    is $result, 'image/png', 'png case returns properly';

    $result = BOM::Event::Actions::Client::IdentityVerification::_detect_mime_type(
        '/9j/4AAQSkZJRgABAgAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0H');

    is $result, 'image/jpg', 'jpg case returns properly';

};

subtest 'testing photo being sent as paramter - undef file type' => sub {
    my $idv_event_handler = BOM::Event::Process->new(category => 'generic')->actions->{identity_verification_requested};

    my $email = 'test_verify_photo_unfef_file_type@binary.com';
    my $user  = BOM::User->create(
        email          => $email,
        password       => "pwd123",
        email_verified => 1,
    );

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        binary_user_id => $user->id,
    });

    $client->user($user);
    $client->binary_user_id($user->id);
    $user->add_client($client);
    $client->save;

    my $args = {
        loginid => $client->loginid,
    };

    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->user->id);
    $updates = 0;

    my $idv_document = {
        issuing_country => 'br',
        number          => '666.456.789-33',
        type            => 'cpf',
    };
    $idv_model->add_document($idv_document);

    my $redis = BOM::Config::Redis::redis_events();
    $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 1);

    my $services_track_mock = Test::MockModule->new('BOM::Event::Services::Track');
    my $track_args;

    $services_track_mock->mock(
        'document_upload',
        sub {
            $track_args = shift;
            return Future->done(1);
        });

    my $s3_client_mock = Test::MockModule->new('BOM::Platform::S3Client');
    $s3_client_mock->mock(
        'upload_binary',
        sub {
            return Future->done(1);
        });

    $client->address_line_1('Fake St 123');
    $client->address_line_2('apartamento 22');
    $client->address_postcode('12345900');
    $client->residence('br');
    $client->first_name('John');
    $client->last_name('Doe');
    $client->date_of_birth('1996-02-12');
    $client->save();

    @emissions = ();

    ok $idv_event_handler->($args)->get, 'the event processed without error';

    # a verify process is dispatched!
    ok $idv_proc_handler->({
            status   => 'verified',
            messages => ['NAME_MISMATCH'],
            provider => {
                name         => 'zaig',
                dataProvider => 'true'
            },
            report => {
                full_name => "John Mary Doe",
                photo     => "Not Available",
            },
            id => $client->loginid,
        })->get, 'the IDV response processed without error';

    cmp_deeply [@emissions],
        [{
            idv_verification => {
                address => {
                    postcode  => $client->address_postcode,
                    city      => $client->address_city,
                    residence => $client->residence,
                    line_1    => $client->address_line_1,
                    line_2    => $client->address_line_2,
                },
                profile => {
                    first_name => $client->first_name,
                    id         => $client->loginid,
                    birthdate  => $client->date_of_birth,
                    last_name  => $client->last_name
                },
                document => $idv_document,
            }
        },
        {
            age_verified => {
                loginid    => $client->loginid,
                properties => {
                    website_name  => $brand->website_name,
                    live_chat_url => $live_chat_url,
                    contact_url   => $contact_url,
                    poi_url       => $poi_url,
                    email         => $client->email,
                    name          => $client->first_name
                }}
        },
        {
            sync_mt5_accounts_status => {
                client_loginid => $client->loginid,
                binary_user_id => $client->binary_user_id,
            }}
        ],
        'Expected emissions for a verified request';

    my $document = $idv_model->get_last_updated_document;

    my $dbic = BOM::Database::UserDB::rose_db(operation => 'replica')->dbic;

    my $check = $dbic->run(
        fixup => sub {
            $_->selectall_arrayref("SELECT photo_id FROM idv.document_check where document_id = ?", {Slice => {}}, $document->{id});
        });

    cmp_deeply $check, [{photo_id => []}], 'photo id is not existant';

    is $track_args, undef, 'No track was sent';

    $document = $idv_model->get_last_updated_document;

    cmp_deeply(
        $document,
        {
            'document_number'          => '666.456.789-33',
            'status'                   => 'verified',
            'document_expiration_date' => undef,
            'is_checked'               => 1,
            'issuing_country'          => 'br',
            'status_messages'          => '["NAME_MISMATCH"]',
            'id'                       => re('\d+'),
            'document_type'            => 'cpf'
        },
        'Document has verified from pass'
    );
};

subtest 'testing pending status (QA Provider special case)' => sub {
    my $idv_event_handler = BOM::Event::Process->new(category => 'generic')->actions->{identity_verification_requested};
    my $mock_qa           = Test::MockModule->new('BOM::Config');
    $mock_qa->mock('on_qa' => 1);

    my $email = 'test_verify_pending@binary.com';

    my $user = BOM::User->create(
        email          => $email,
        password       => "pwd123",
        email_verified => 1,
    );

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        binary_user_id => $user->id,
    });

    $client->user($user);
    $client->binary_user_id($user->id);
    $user->add_client($client);
    $client->save;

    my $args = {
        loginid => $client->loginid,
    };

    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->user->id);
    $updates = 0;

    my $idv_document = {
        issuing_country => 'qq',
        number          => 'A000000000',
        type            => 'passport',
    };
    $idv_model->add_document($idv_document);

    my $redis = BOM::Config::Redis::redis_events();
    $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 1);

    $client->address_line_1('Fake St 123');
    $client->address_line_2('apartamento 22');
    $client->address_postcode('12345900');
    $client->residence('br');
    $client->first_name('John');
    $client->last_name('Doe');
    $client->date_of_birth('1997-03-12');
    $client->save();

    @emissions = ();

    ok $idv_event_handler->($args)->get, 'the event processed without error';

    # a verify process is dispatched!
    ok $idv_proc_handler->({
            status   => 'pending',
            messages => [],
            provider => {
                name         => 'qa',
                dataProvider => 'true'
            },
            response_body => {
                full_name => "John Doe",
                birthdate => "1997-03-12",
            },
            report => {
                full_name => "John Doe",
                birthdate => "1997-03-12",
            },
            id => $client->loginid,
        })->get, 'the IDV response processed without error';

    cmp_deeply [@emissions],
        [{
            idv_verification => {
                address => {
                    postcode  => $client->address_postcode,
                    city      => $client->address_city,
                    residence => $client->residence,
                    line_1    => $client->address_line_1,
                    line_2    => $client->address_line_2,
                },
                profile => {
                    first_name => $client->first_name,
                    id         => $client->loginid,
                    birthdate  => $client->date_of_birth,
                    last_name  => $client->last_name
                },
                document => $idv_document,
            }
        },
        {
            sync_mt5_accounts_status => {
                client_loginid => $client->loginid,
                binary_user_id => $client->binary_user_id,
            }}
        ],
        'Expected emissions for a pending request';

    ok !$client->status->age_verification, 'not age verification';

    my $document = $idv_model->get_last_updated_document;

    cmp_deeply(
        $document,
        {
            'document_number'          => 'A000000000',
            'status'                   => 'pending',
            'document_expiration_date' => undef,
            'is_checked'               => 1,
            'issuing_country'          => 'qq',
            'status_messages'          => '[]',
            'id'                       => re('\d+'),
            'document_type'            => 'passport'
        },
        'Document has left hanging in the pending status'
    );

    $mock_qa->unmock_all();
};

subtest 'IDV lookback' => sub {
    my $idv_event_handler = BOM::Event::Process->new(category => 'generic')->actions->{identity_verification_requested};
    my $action_handler    = BOM::Event::Process->new(category => 'generic')->actions->{poi_check_rules};
    my $test_client       = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'poicheckrulesidv@test.com',
    });
    my $vrtc_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
        email       => 'poicheckrulesidv@test.com',
    });

    my $email = $test_client->email;
    my $user  = BOM::User->create(
        email          => $test_client->email,
        password       => "hello",
        email_verified => 1,
    );

    $user->add_client($test_client);
    $user->add_client($vrtc_client);

    my $test_client_mock = Test::MockModule->new('BOM::User::Client');
    $test_client_mock->mock(
        'latest_poi_by',
        sub {
            return ('idv');
        });

    my $dog_mock = Test::MockModule->new('DataDog::DogStatsd::Helper');
    my @doggy_bag;

    $dog_mock->mock(
        'stats_inc',
        sub {
            push @doggy_bag, [@_];
        });

    my $idv_mock           = Test::MockModule->new('BOM::Event::Actions::Client::IdentityVerification');
    my $lookbackCalledWith = {};
    my $lookbackCalled;

    $idv_mock->mock(
        'idv_mismatch_lookback',
        sub {
            ($lookbackCalledWith) = @_;
            $lookbackCalled = 1;
            return Future->done;
        });

    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->user->id);
    $updates = 0;

    my $document = {
        issuing_country => 'ar',
        number          => '123456788',
        type            => 'dni',
    };
    $idv_model->add_document($document);

    @emissions = ();
    $client->residence('ar');
    $client->first_name('John');
    $client->last_name('Doe');
    $client->date_of_birth('1997-03-12');
    $client->save();

    my $redis = BOM::Config::Redis::redis_events();
    $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 1);
    ok $idv_event_handler->($args)->get, 'the event processed without error';

    # a verify process is dispatched!
    ok $idv_proc_handler->({
            status   => 'refuted',
            messages => ['NAME_MISMATCH', 'DOB_MISMATCH'],
            provider => {
                name         => 'metamap',
                dataProvider => 'false'
            },
            report => {

            },
            id => $client->loginid,
        })->get, 'the IDV response processed without error';

    $client = BOM::User::Client->new({loginid => $client->loginid});

    ok $client->status->poi_name_mismatch, 'client has name mismatch';

    ok $client->status->poi_dob_mismatch, 'client has dob mismatch';

    cmp_deeply [@emissions],
        [{
            idv_verification => {
                address => {
                    postcode  => $client->address_postcode,
                    city      => $client->address_city,
                    residence => $client->residence,
                    line_1    => $client->address_line_1,
                    line_2    => $client->address_line_2,
                },
                profile => {
                    first_name => $client->first_name,
                    id         => $client->loginid,
                    birthdate  => $client->date_of_birth,
                    last_name  => $client->last_name
                },
                document => $document,
            }
        },
        {
            identity_verification_rejected => {
                loginid    => $client->loginid,
                properties => {
                    authentication_url => $authentication_url,
                    live_chat_url      => $live_chat_url,
                    title              => 'We were unable to verify your document details',
                }}
        },
        {
            sync_mt5_accounts_status => {
                client_loginid => $client->loginid,
                binary_user_id => $client->binary_user_id,
            }}
        ],
        'Expected emissions for a refuted IDV request';

    # now try to lookback
    $lookbackCalled = 0;

    ok !$action_handler->({
            loginid => $client->loginid,
        })->get, 'POI check rules attempted';

    ok !$lookbackCalled, 'lookback was not called';

    # again
    $document = {
        issuing_country => 'ar',
        number          => '123456788-1',
        type            => 'dni',
    };
    $idv_model->add_document($document);
    @emissions = ();

    my $exception = exception {
        ok $idv_proc_handler->({
                id            => $client->loginid,
                status        => 'verified',
                messages      => ['ADDRESS_VERIFIED'],
                response_body => {},
                request_body  => {},
                report        => {},
            })->get, 'the IDV response processed without error';
    };

    ok $exception =~ qr/No document check found/, 'exception thrown: no check found';

    my $idv_document_model = $idv_model->get_standby_document;

    $idv_model->update_document_check({
        document_id  => $idv_document_model->{id},
        status       => +BOM::Event::Actions::Client::IdentityVerification::IDV_DOCUMENT_STATUS->{pending},
        messages     => [+BOM::Event::Actions::Client::IdentityVerification::IDV_MESSAGES->{VERIFICATION_STARTED},],
        provider     => 'zaig',
        request_body => '{}',
    });

    ok $idv_proc_handler->({
            status   => 'refuted',
            messages => ['NAME_MISMATCH', 'DOB_MISMATCH'],
            provider => {
                name         => 'metamap',
                dataProvider => 'true'
            },
            report => {birthdate => '1989-10-10'},
            id     => $client->loginid,
        })->get, 'the IDV response processed without error';

    ok !$action_handler->({
            loginid => $client->loginid,
        })->get, 'POI check rules attempted';

    ok !$lookbackCalled, 'lookback was not called';

    cmp_deeply [@emissions],
        [{
            identity_verification_rejected => {
                loginid    => $client->loginid,
                properties => {
                    authentication_url => $authentication_url,
                    live_chat_url      => $live_chat_url,
                    title              => 'We were unable to verify your document details',
                }}
        },
        {
            sync_mt5_accounts_status => {
                client_loginid => $client->loginid,
                binary_user_id => $client->binary_user_id,
            }}
        ],
        'Expected emissions for a refuted IDV lookback';

    # again
    @doggy_bag = ();
    $document  = {
        issuing_country => 'ar',
        number          => '123456788-2',
        type            => 'dni',
    };
    $idv_model->add_document($document);

    $exception = exception {
        ok $idv_proc_handler->({
                id            => $client->loginid,
                status        => 'verified',
                messages      => ['ADDRESS_VERIFIED'],
                response_body => {},
                request_body  => {},
                report        => {},
            })->get, 'the IDV response processed without error';
    };

    ok $exception =~ qr/No document check found/, 'exception thrown: no check found';

    $idv_document_model = $idv_model->get_standby_document;

    $idv_model->update_document_check({
        document_id  => $idv_document_model->{id},
        status       => +BOM::Event::Actions::Client::IdentityVerification::IDV_DOCUMENT_STATUS->{pending},
        messages     => [+BOM::Event::Actions::Client::IdentityVerification::IDV_MESSAGES->{VERIFICATION_STARTED},],
        provider     => 'zaig',
        request_body => '{}',
    });

    @emissions = ();
    ok $idv_proc_handler->({
            status   => 'refuted',
            messages => ['NAME_MISMATCH', 'DOB_MISMATCH'],
            provider => {
                name         => 'metamap',
                dataProvider => 'true'
            },
            report => {full_name => 'The Chosen One'},
            id     => $client->loginid,
        })->get, 'the IDV response processed without error';

    ok !$action_handler->({
            loginid => $client->loginid,
        })->get, 'POI check rules attempted';

    ok !$lookbackCalled, 'lookback was not called';

    cmp_deeply [@emissions],
        [{
            identity_verification_rejected => {
                loginid    => $client->loginid,
                properties => {
                    authentication_url => $authentication_url,
                    live_chat_url      => $live_chat_url,
                    title              => 'We were unable to verify your document details',
                }}
        },
        {
            sync_mt5_accounts_status => {
                client_loginid => $client->loginid,
                binary_user_id => $client->binary_user_id,
            }}
        ],
        'Expected emissions for a refuted IDV callback';

    # call again on a full report

    $idv_model->add_document({
        issuing_country => 'ar',
        number          => '123456788-3',
        type            => 'dni',
    });

    $exception = exception {
        ok $idv_proc_handler->({
                id            => $client->loginid,
                status        => 'verified',
                messages      => ['ADDRESS_VERIFIED'],
                response_body => {},
                request_body  => {},
                report        => {},
            })->get, 'the IDV response processed without error';
    };

    ok $exception =~ qr/No document check found/, 'exception thrown: no check found';

    $idv_document_model = $idv_model->get_standby_document;

    $idv_model->update_document_check({
        document_id  => $idv_document_model->{id},
        status       => +BOM::Event::Actions::Client::IdentityVerification::IDV_DOCUMENT_STATUS->{pending},
        messages     => [+BOM::Event::Actions::Client::IdentityVerification::IDV_MESSAGES->{VERIFICATION_STARTED},],
        provider     => 'zaig',
        request_body => '{}',
    });

    @emissions = ();
    ok $idv_proc_handler->({
            status   => 'refuted',
            messages => ['NAME_MISMATCH', 'DOB_MISMATCH'],
            provider => {
                name         => 'zaig',
                dataProvider => 'true'
            },
            report => {
                full_name => 'The Chosen One',
                birthdate => '1989-10-10'
            },
            request_body  => {request  => 'set'},
            response_body => {resposne => 'get'},
            id            => $client->loginid,
        })->get, 'the IDV response processed without error';

    ok !$action_handler->({
            loginid => $client->loginid,
        })->get, 'POI check rules attempted';

    ok $lookbackCalled, 'lookback was called';

    ok delete $lookbackCalledWith->{client}, 'there was a client';

    cmp_deeply $lookbackCalledWith,
        {
        messages => ['NAME_MISMATCH', 'DOB_MISMATCH'],
        document => {
            document_expiration_date => undef,
            status_messages          => '["NAME_MISMATCH", "DOB_MISMATCH"]',
            issuing_country          => 'ar',
            status                   => 'refuted',
            document_type            => 'dni',
            document_number          => '123456788-3',
            id                       => re('\d+'),
            is_checked               => 1
        },
        response_body => {resposne => 'get'},
        request_body  => {request  => 'set'},
        report        => {
            full_name => 'The Chosen One',
            birthdate => '1989-10-10'
        },
        provider => 'zaig',
        pictures => undef
        },
        'expected arguments for lookback call';

    cmp_deeply [@emissions],
        [{
            identity_verification_rejected => {
                loginid    => $client->loginid,
                properties => {
                    authentication_url => $authentication_url,
                    live_chat_url      => $live_chat_url,
                    title              => 'We were unable to verify your document details',
                }}
        },
        {
            sync_mt5_accounts_status => {
                client_loginid => $client->loginid,
                binary_user_id => $client->binary_user_id,
            }}
        ],
        'Expected emissions for a refuted IDV callback';

    cmp_deeply [@doggy_bag], [['event.idv.client_verification.result', {'tags' => ['result:name_mismatch', 'result:dob_mismatch']}]],
        'Expected dog calls';

    # now that we know the lookback is called we will unmock and observe side effects
    @doggy_bag = ();

    $idv_mock->unmock('idv_mismatch_lookback');

    @emissions = ();

    ok !$action_handler->({
            loginid => $client->loginid,
        })->get, 'POI check rules attempted';

    $client = BOM::User::Client->new({loginid => $client->loginid});

    ok $client->status->poi_name_mismatch, 'still on name mismatch';
    ok $client->status->poi_dob_mismatch,  'still on dob mismatch';
    ok !$client->status->age_verification, 'still not age verified';

    my $idv_document       = $idv_model->get_last_updated_document();
    my $idv_document_check = $idv_model->get_document_check_detail($idv_document->{id});

    cmp_deeply $idv_document,
        {
        'is_checked'               => 1,
        'status'                   => 'refuted',
        'document_type'            => 'dni',
        'document_expiration_date' => undef,
        'document_number'          => '123456788-3',
        'id'                       => re('\d+'),
        'status_messages'          => '["NAME_MISMATCH", "DOB_MISMATCH"]',
        'issuing_country'          => 'ar'
        },
        'expected document data';

    cmp_deeply $idv_document_check,
        {
        'response'     => '{"resposne": "get"}',
        'id'           => re('\d+'),
        'provider'     => 'zaig',
        'photo_id'     => [],
        'request'      => '{"request": "set"}',
        'requested_at' => ignore(),
        'responded_at' => ignore(),
        'report'       => '{"birthdate": "1989-10-10", "full_name": "The Chosen One"}'
        },
        'expected document check data';

    cmp_deeply [@doggy_bag], [['event.idv.client_verification.result', {'tags' => ['result:name_mismatch', 'result:dob_mismatch']}]],
        'Expected dog calls';

    cmp_deeply [@emissions],
        [{
            identity_verification_rejected => {
                loginid    => $client->loginid,
                properties => {
                    authentication_url => $authentication_url,
                    live_chat_url      => $live_chat_url,
                    title              => 'We were unable to verify your document details',
                }}
        },
        {
            sync_mt5_accounts_status => {
                client_loginid => $client->loginid,
                binary_user_id => $client->binary_user_id,
            }}
        ],
        'Expected emissions for a refuted IDV callback';

    # make dob mismatch go away
    @emissions = ();
    @doggy_bag = ();
    $client->date_of_birth('1989-10-10');
    $client->save;

    ok !$action_handler->({
            loginid => $client->loginid,
        })->get, 'POI check rules attempted';

    $client = BOM::User::Client->new({loginid => $client->loginid});
    ok $client->status->poi_name_mismatch, 'still on name mismatch';
    ok !$client->status->poi_dob_mismatch, 'dob mismatch has gone away';
    ok !$client->status->age_verification, 'still not age verified';

    $idv_document       = $idv_model->get_last_updated_document();
    $idv_document_check = $idv_model->get_document_check_detail($idv_document->{id});

    cmp_deeply $idv_document,
        {
        'is_checked'               => 1,
        'status'                   => 'refuted',
        'document_type'            => 'dni',
        'document_expiration_date' => undef,
        'document_number'          => '123456788-3',
        'id'                       => re('\d+'),
        'status_messages'          => '["NAME_MISMATCH"]',
        'issuing_country'          => 'ar'
        },
        'expected document data';

    cmp_deeply $idv_document_check, {
        'response'     => '{"resposne": "get"}',
        'id'           => re('\d+'),
        'provider'     => 'zaig',
        'photo_id'     => [],
        'request'      => '{"request": "set"}',
        'requested_at' => ignore(),
        'responded_at' => ignore(),
        'report'       => '{"birthdate": "1989-10-10", "full_name": "The Chosen One"}'

        },
        'expected document check data';

    cmp_deeply [@doggy_bag], [['event.idv.client_verification.result', {'tags' => ['result:name_mismatch',]}]], 'Expected dog calls';

    cmp_deeply [@emissions],
        [{
            identity_verification_rejected => {
                loginid    => $client->loginid,
                properties => {
                    authentication_url => $authentication_url,
                    live_chat_url      => $live_chat_url,
                    title              => 'We were unable to verify your document details',
                }}
        },
        {
            sync_mt5_accounts_status => {
                client_loginid => $client->loginid,
                binary_user_id => $client->binary_user_id,
            }}
        ],
        'Expected emissions for a refuted IDV callback';

    # make name mismatch go away
    @doggy_bag = ();
    @emissions = ();
    $client->first_name('The Chosen');
    $client->last_name('one');
    $client->save;

    ok !$action_handler->({
            loginid => $client->loginid,
        })->get, 'POI check rules attempted';

    $client = BOM::User::Client->new({loginid => $client->loginid});
    ok !$client->status->poi_name_mismatch, 'name mismatch has gone away';
    ok !$client->status->poi_dob_mismatch,  'dob mismatch has gone away';
    ok $client->status->age_verification,   'age verified!';

    $idv_document       = $idv_model->get_last_updated_document();
    $idv_document_check = $idv_model->get_document_check_detail($idv_document->{id});

    cmp_deeply $idv_document,
        {
        'is_checked'               => 1,
        'status'                   => 'verified',
        'document_type'            => 'dni',
        'document_expiration_date' => undef,
        'document_number'          => '123456788-3',
        'id'                       => re('\d+'),
        'status_messages'          => '[]',
        'issuing_country'          => 'ar'
        },
        'expected document data';

    cmp_deeply $idv_document_check, {
        'response'     => '{"resposne": "get"}',
        'id'           => re('\d+'),
        'provider'     => 'zaig',
        'photo_id'     => [],
        'request'      => '{"request": "set"}',
        'requested_at' => ignore(),
        'responded_at' => ignore(),
        'report'       => '{"birthdate": "1989-10-10", "full_name": "The Chosen One"}'

        },
        'expected document check data';

    cmp_deeply [@emissions],
        [{
            age_verified => {
                loginid    => $client->loginid,
                properties => {
                    website_name  => $brand->website_name,
                    live_chat_url => $live_chat_url,
                    contact_url   => $contact_url,
                    poi_url       => $poi_url,
                    email         => $client->email,
                    name          => $client->first_name
                }}
        },
        {
            sync_mt5_accounts_status => {
                client_loginid => $client->loginid,
                binary_user_id => $client->binary_user_id,
            }}
        ],
        'Expected emissions for a refuted IDV callback';

    cmp_deeply [@doggy_bag], [['event.idv.client_verification.result', {'tags' => ['result:age_verified_corrected',]}]], 'Expected dog calls';

    $idv_mock->unmock_all;
    $test_client_mock->unmock_all;
    $dog_mock->unmock_all;
};

subtest 'protect the json encode test' => sub {
    my $idv_event_handler = BOM::Event::Process->new(category => 'generic')->actions->{identity_verification_requested};
    my $idv_mock          = Test::MockModule->new('BOM::User::IdentityVerification');
    my $request_body_update;

    $idv_mock->mock(
        'update_document_check',
        sub {
            my (undef, $args) = @_;

            $request_body_update = $args->{request_body};

            return $idv_mock->original('update_document_check')->(@_);
        });

    my $tests = [{
            title => 'No response',
            hash  => {
                provider => {
                    name         => 'qa',
                    dataProvider => 'true'
                },
                response_body => undef,
                request_body  => {request => 'sent'},
                report        => {
                    full_name => $personal_info->{FullName},
                    birthdate => $personal_info->{DOB},
                },
            }
        },
        {
            title => 'No request',
            hash  => {
                provider => {
                    name         => 'qa',
                    dataProvider => 'true'
                },
                response_body => {response => 'asdf'},
                request_body  => undef,
                report        => {
                    full_name => $personal_info->{FullName},
                    birthdate => $personal_info->{DOB},
                },
            }
        },
        {
            title => 'No report',
            hash  => {
                provider => {
                    name         => 'qa',
                    dataProvider => 'true'
                },
                response_body => {response => 'asdf'},
                request_body  => {request  => 'sent'},
                report        => undef,
            }
        },
        {
            title => 'Full house',
            hash  => {
                provider => {
                    name         => 'qa',
                    dataProvider => 'true'
                },
                response_body => {response => 'asdf'},
                request_body  => {request  => 'sent'},
                report        => {
                    expiry_date => '1999-10-10',
                    full_name   => $personal_info->{FullName},
                    birthdate   => $personal_info->{DOB},
                },
            }
        },
        {
            title => 'Empty house',
            hash  => {
                provider => {
                    name         => 'qa',
                    dataProvider => 'true'
                },
                response_body => undef,
                request_body  => undef,
                report        => undef,
            }
        },
        {
            title => 'Scalars at the house',
            hash  => {
                provider => {
                    name         => 'qa',
                    dataProvider => 'true'
                },
                response_body => 'failed',
                request_body  => 'error',
                report        => 'what',
            }
        },
    ];

    my $c = 0;

    for my $test ($tests->@*) {
        subtest $test->{title} => sub {
            for my $status (qw/verified failed refuted callback pending/) {
                subtest "status $status" => sub {
                    $c++;

                    my $email = $c . $status . 'protecting_the_json_encode@test.com';
                    my $user  = BOM::User->create(
                        email          => $email,
                        password       => "pwd123",
                        email_verified => 1,
                    );

                    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                        broker_code    => 'CR',
                        email          => $email,
                        binary_user_id => $user->id,
                    });

                    $client->user($user);
                    $client->binary_user_id($user->id);
                    $user->add_client($client);
                    $client->save;
                    $args = {
                        loginid => $client->loginid,
                    };

                    $updates  = 0;
                    $encoding = {};

                    my $idv_model    = BOM::User::IdentityVerification->new(user_id => $client->user->id);
                    my $idv_document = {
                        issuing_country => 'ke',
                        number          => '123450' . $c,
                        type            => 'national_id',
                        additional      => $status,
                    };
                    $idv_model->add_document($idv_document);

                    my $redis = BOM::Config::Redis::redis_events();
                    $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 1);

                    @emissions = ();

                    ok $idv_event_handler->($args)->get, 'the event processed without error';

                    # a verify process is dispatched!
                    ok $idv_proc_handler->({
                            status   => $status,
                            provider => {
                                name         => 'smile_identity',
                                dataProvider => 'true'
                            },
                            $test->{hash}->%*,
                            id => $client->loginid,
                        })->get, 'the IDV response processed without error';

                    my @expected = ({
                            idv_verification => {
                                address => {
                                    postcode  => $client->address_postcode,
                                    city      => $client->address_city,
                                    residence => $client->residence,
                                    line_1    => $client->address_line_1,
                                    line_2    => $client->address_line_2,
                                },
                                profile => {
                                    first_name => $client->first_name,
                                    id         => $client->loginid,
                                    birthdate  => $client->date_of_birth,
                                    last_name  => $client->last_name
                                },
                                document => $idv_document,
                            }});

                    push @expected,
                        {
                        age_verified => {
                            loginid    => $client->loginid,
                            properties => {
                                website_name  => $brand->website_name,
                                live_chat_url => $live_chat_url,
                                contact_url   => $contact_url,
                                poi_url       => $poi_url,
                                email         => $client->email,
                                name          => $client->first_name
                            }}}
                        if $status eq 'verified';

                    push @expected,
                        {
                        identity_verification_rejected => {
                            loginid    => $client->loginid,
                            properties => {
                                authentication_url => $authentication_url,
                                live_chat_url      => $live_chat_url,
                                title              => 'We were unable to verify your document details',
                            }}}
                        if $status eq 'refuted';

                    push @expected,
                        {
                        sync_mt5_accounts_status => {
                            client_loginid => $client->loginid,
                            binary_user_id => $client->binary_user_id,
                        }};

                    cmp_deeply [@emissions], [@expected], "Expected emissions for a $status IDV callback";

                    my $document = $idv_model->get_last_updated_document;

                    my $db_status = $status;

                    $db_status = 'deferred' if $db_status eq 'callback';

                    is $document->{status}, $db_status, 'Expected status';

                    my $idv_document_check = $idv_model->get_document_check_detail($document->{id});

                    if ($test->{hash}->{response_body} && ref($test->{hash}->{response_body}) eq 'HASH') {
                        cmp_deeply decode_json_utf8($idv_document_check->{response}), $test->{hash}->{response_body}, 'Expected response';
                    } else {
                        ok !$idv_document_check->{response}, 'No response';
                    }

                    if ($test->{hash}->{request_body} && ref($test->{hash}->{request_body}) eq 'HASH') {
                        cmp_deeply decode_json_utf8($idv_document_check->{request}), $test->{hash}->{request_body}, 'Expected request';
                    } else {
                        # instead of checking the actual document check content
                        # we will check for the last mocked argument passed for the request body
                        # the reason is, the first document check update (the one for verification started)
                        # will add a payload that is defined, afterwards the db function will perform
                        # a coalesce over that column value, the value remaining is not undef due to this
                        # so the expecting behavior would be to actually have some data

                        ok !$request_body_update,          'No request at the last update';
                        ok $idv_document_check->{request}, 'leftover request body';
                    }

                    if ($test->{hash}->{report} && ref($test->{hash}->{report}) eq 'HASH') {
                        cmp_deeply decode_json_utf8($idv_document_check->{report}), $test->{hash}->{report}, 'Expected report';
                    } else {
                        ok !$idv_document_check->{report}, 'No report';
                    }

                    if ($test->{hash}->{report} && ref($test->{hash}->{report}) eq 'HASH' && $test->{hash}->{report}->{expiry_date}) {
                        is $document->{document_expiration_date}, $test->{hash}->{report}->{expiry_date} . ' 00:00:00', 'Expected expiration date';
                    } else {
                        ok !$document->{document_expiration_date}, 'No expiration_date';
                    }
                };
            }
        };
    }

    $idv_mock->unmock_all;
};

sub _reset_submissions {
    my $user_id = shift;
    my $redis   = BOM::Config::Redis::redis_events();

    $redis->set(BOM::User::IdentityVerification::IDV_REQUEST_PER_USER_PREFIX . $user_id, 0);
}

done_testing();
