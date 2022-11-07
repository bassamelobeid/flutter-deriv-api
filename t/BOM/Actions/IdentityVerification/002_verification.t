use strict;
use warnings;

use Test::More;
use Log::Any::Test;
use Log::Any qw($log);
use Test::MockModule;
use Test::Deep;
use Test::Fatal;

use Date::Utility;
use Future::Exception;
use HTTP::Response;
use JSON::MaybeUTF8 qw(encode_json_utf8 decode_json_utf8);

use BOM::Config::Redis;
use BOM::Event::Process;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::User::IdentityVerification;

my $idv_mock = Test::MockModule->new('BOM::Event::Actions::Client::IdentityVerification');
my $encoding = {};
# every execution branch of the microservice handler must use this number
# of json functions exhaustively
my $expected_json_usage = {
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

my @requests;
my ($resp, $verification_status, $personal_info_status, $personal_info, $args) = undef;
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

my $mock_http = Test::MockModule->new('Net::Async::HTTP');
$mock_http->mock(
    POST => sub {
        push @requests, $_[2];    # request body

        return $resp->() if ref $resp eq 'CODE';
        return $resp;
    });    # prevent making real calls

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

subtest 'verify identity by smile_identity through microservice is passed and data are valid' => sub {
    $args = {
        loginid => $client->loginid,
    };

    $updates  = 0;
    $encoding = {};

    $idv_model->add_document({
        issuing_country => 'ke',
        number          => '12345',
        type            => 'national_id'
    });

    $client->address_line_1('Fake St 123');
    $client->address_line_2('apartamento 22');
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

    $resp = Future->done(
        HTTP::Response->new(
            200, undef, undef,
            encode_json_utf8({
                    status => 'pass',
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
                })));

    ok $idv_event_handler->($args)->get, 'the event processed without error';

    cmp_deeply($encoding, $expected_json_usage, 'Expected JSON usage');
    cmp_deeply decode_json_utf8($requests[0]),
        {
        document => {
            issuing_country => 'ke',
            type            => 'national_id',
            number          => '12345',
        },
        profile => {
            login_id   => 'CR10000',
            first_name => 'John',
            last_name  => 'Doe',
            birthdate  => '1988-02-12',
        },
        address => {
            line_1    => 'Fake St 123',
            line_2    => 'apartamento 22',
            postcode  => '12345900',
            residence => 'ar'
        },
        },
        'request body is correct';
    is $updates, 2, 'update document triggered twice correctly';

    ok !$client->status->poi_name_mismatch, 'poi_name_mismatch is removed correctly';
    ok $client->status->age_verification,   'age verified correctly';

    is $mock_idv_status, 'verified', 'verify_identity returns `verified` status';
};

subtest 'microservice address verified' => sub {
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
    @requests = ();

    $idv_model->add_document({
        issuing_country => 'br',
        number          => '123.456.789-33',
        type            => 'cpf'
    });

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

    $resp = Future->done(
        HTTP::Response->new(
            200, undef, undef,
            encode_json_utf8({
                    status   => 'verified',
                    messages => ['ADDRESS_VERIFIED']})));

    ok $idv_event_handler->($args)->get, 'the event processed without error';

    cmp_deeply decode_json_utf8($requests[0]),
        {
        document => {
            issuing_country => 'br',
            type            => 'cpf',
            number          => '123.456.789-33',
        },
        profile => {
            login_id   => $client->loginid,
            first_name => 'John',
            last_name  => 'Doe',
            birthdate  => '1988-02-12',
        },
        address => {
            line_1    => 'Fake St 123',
            line_2    => 'apartamento 22',
            postcode  => '12345900',
            residence => 'br',
        },
        },
        'request body is correct';
    is $updates, 2, 'update document triggered twice correctly';

    ok !$client->status->poi_name_mismatch, 'poi_name_mismatch is removed correctly';
    ok $client->status->age_verification,   'age verified correctly';
    ok $client->fully_authenticated(),      'client is fully authenticated';
    is $client->get_authentication('IDV')->{status}, 'pass', 'PoA with IDV';
    ok !$client->status->unwelcome, 'client unwelcome is removed';

    is $mock_idv_status, 'verified', 'verify_identity returns `verified` status';
};

subtest 'microservice is unavailable' => sub {
    $resp = Future->done(HTTP::Response->new(200, undef, undef, undef));

    $encoding = {};
    $idv_model->add_document({
        issuing_country => 'ng',
        number          => '99989',
        type            => 'dl'
    });

    ok $idv_event_handler->($args)->get, 'the event processed without error';

    my $doc  = $idv_model->get_last_updated_document();
    my $msgs = decode_json_utf8 $doc->{status_messages};
    $expected_json_usage->{encode_json_text} = 2;    # non microservice execution branch does not include $report

    cmp_deeply($encoding, $expected_json_usage, 'Expected JSON usage');
    is_deeply $msgs, ['UNAVAILABLE_MICROSERVICE'], 'message is correct';
};

subtest 'verify_process - apply side effects' => sub {

    my $idv_event_handler = BOM::Event::Process->new(category => 'generic')->actions->{identity_verification_processed};

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

    my $args = {
        loginid       => $client->loginid,
        status        => 'verified',
        response_hash => {
            status   => 'verified',
            messages => ['ADDRESS_VERIFIED']
        },
        message => ['ADDRESS_VERIFIED'],

    };

    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->user->id);
    $updates  = 0;
    @requests = ();

    $idv_model->add_document({
        issuing_country => 'br',
        number          => '123.456.789-33',
        type            => 'cpf'
    });

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

    ok $idv_event_handler->($args)->get, 'the event processed without error';

    ok $client->status->age_verification, 'age verified correctly';
    ok $client->fully_authenticated(),    'client is fully authenticated';
    is $client->get_authentication('IDV')->{status}, 'pass', 'PoA with IDV';

};

subtest 'testing failed status' => sub {
    my $idv_event_handler = BOM::Event::Process->new(category => 'generic')->actions->{identity_verification_requested};

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
    $updates  = 0;
    @requests = ();

    $idv_model->add_document({
        issuing_country => 'br',
        number          => '123.456.789-33',
        type            => 'cpf'
    });

    $client->address_line_1('Fake St 123');
    $client->address_line_2('apartamento 22');
    $client->address_postcode('12345900');
    $client->residence('br');
    $client->first_name('John');
    $client->last_name('Doe');
    $client->date_of_birth('1988-02-12');
    $client->save();

    $resp = Future->done(
        HTTP::Response->new(
            200, undef, undef,
            encode_json_utf8({
                    status   => 'failed',
                    messages => ['NAME_MISMATCH']})));

    ok $idv_event_handler->($args)->get, 'the event processed without error';

    my $document = $idv_model->get_last_updated_document;

    cmp_deeply(
        $document,
        {
            'document_number'          => '123.456.789-33',
            'status'                   => 'failed',
            'document_expiration_date' => undef,
            'is_checked'               => 1,
            'issuing_country'          => 'br',
            'status_messages'          => '["NAME_MISMATCH"]',
            'id'                       => '5',
            'document_type'            => 'cpf'
        },
        'Document has failed status'
    );

};

subtest 'testing pass status' => sub {
    my $idv_event_handler = BOM::Event::Process->new(category => 'generic')->actions->{identity_verification_requested};

    my $email = 'test_verify_pass@binary.com';
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
    $updates  = 0;
    @requests = ();

    $idv_model->add_document({
        issuing_country => 'br',
        number          => '123.456.789-33',
        type            => 'cpf'
    });

    $client->address_line_1('Fake St 123');
    $client->address_line_2('apartamento 22');
    $client->address_postcode('12345900');
    $client->residence('br');
    $client->first_name('John');
    $client->last_name('Doe');
    $client->date_of_birth('1988-02-12');
    $client->save();

    $resp = Future->done(
        HTTP::Response->new(
            200, undef, undef,
            encode_json_utf8({
                    status   => 'pass',
                    messages => [],
                    report   => {full_name => "John Doe"}})));

    ok $idv_event_handler->($args)->get, 'the event processed without error';

    my $document = $idv_model->get_last_updated_document;

    cmp_deeply(
        $document,
        {
            'document_number'          => '123.456.789-33',
            'status'                   => 'refuted',
            'document_expiration_date' => undef,
            'is_checked'               => 1,
            'issuing_country'          => 'br',
            'status_messages'          => '["UNDERAGE", "DOB_MISMATCH"]',
            'id'                       => '6',
            'document_type'            => 'cpf'
        },
        'Document has refuted from pass -  status'
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

    $error = exception {
        $idv_event_handler->($args)->get;
    };
    ok $error=~ /Could not trigger IDV, microservice is not enabled./, 'expected exception caught no idv';

    $idv_microservice = 1;

    my $idv_model_mock = Test::MockModule->new('BOM::User::IdentityVerification');

    my $submissions_left;

    $idv_model_mock->mock(
        'submissions_left',
        sub {
            return $submissions_left;
        });

    $submissions_left = 0;

    $error = exception {
        $idv_event_handler->($args)->get;
    };

    ok $error=~ /No submissions left, IDV request has ignored for loginid: CR10005/, 'expected exception caught no submissions';

    $idv_model_mock->unmock_all();

};

subtest 'testing the exceptions verify_process' => sub {
    my $idv_event_handler = BOM::Event::Process->new(category => 'generic')->actions->{identity_verification_processed};
    my $email             = 'test_exceptions@binary.com';
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

    ok $error=~ /Could not initiate client for loginid: CR0/, 'expected exception caught';

    $args = {
        loginid => $client->loginid,
    };

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

    $error = exception {
        $idv_event_handler->($args)->get;
    };
    ok $error=~ /Could not trigger IDV, microservice is not enabled./, 'expected exception caught no idv';

    $idv_microservice = 1;

    my $idv_model_mock = Test::MockModule->new('BOM::User::IdentityVerification');

    my $submissions_left;

    $idv_model_mock->mock(
        'submissions_left',
        sub {
            return $submissions_left;
        });

    $submissions_left = 0;

    $error = exception {
        $idv_event_handler->($args)->get;
    };

    ok $error=~ /No submissions left, IDV request has ignored for loginid: CR10006/, 'expected exception caught no submissions';

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
    $updates  = 0;
    @requests = ();

    $idv_model->add_document({
        issuing_country => 'br',
        number          => '123.456.789-33',
        type            => 'cpf'
    });

    $client->address_line_1('Fake St 123');
    $client->address_line_2('apartamento 22');
    $client->address_postcode('12345900');
    $client->residence('br');
    $client->first_name('John');
    $client->last_name('Doe');
    $client->date_of_birth('1988-02-12');
    $client->save();

    $resp = Future->done(
        HTTP::Response->new(
            200, undef, undef,
            encode_json_utf8({
                    status   => 'refuted',
                    messages => [],
                    report   => {birthdate => "1988-02-12"}})));

    ok $idv_event_handler->($args)->get, 'the event processed without error';

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
            'id'                       => '7',
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
    $updates  = 0;
    @requests = ();

    $idv_model->add_document({
        issuing_country => 'br',
        number          => '123.456.789-33',
        type            => 'cpf'
    });

    $client->address_line_1('Fake St 123');
    $client->address_line_2('apartamento 22');
    $client->address_postcode('12345900');
    $client->residence('br');
    $client->first_name('John');
    $client->last_name('Doe');
    $client->date_of_birth('1988-02-12');
    $client->save();

    $resp = Future->done(
        HTTP::Response->new(
            200, undef, undef,
            encode_json_utf8({
                    status   => 'unavailable',
                    messages => [],
                    report   => {birthdate => "1988-02-12"}})));

    ok $idv_event_handler->($args)->get, 'the event processed without error';

    my $document = $idv_model->get_last_updated_document;

    cmp_deeply(
        $document,
        {
            'document_number'          => '123.456.789-33',
            'status'                   => 'failed',
            'document_expiration_date' => undef,
            'is_checked'               => 1,
            'issuing_country'          => 'br',
            'status_messages'          => '[]',
            'id'                       => '8',
            'document_type'            => 'cpf'
        },
        'Document has unavailable status'
    );
};

subtest 'testing pass status and DOB' => sub {
    my $idv_event_handler = BOM::Event::Process->new(category => 'generic')->actions->{identity_verification_requested};

    my $email = 'test_verify_pass+DOB@binary.com';
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
    $updates  = 0;
    @requests = ();

    $idv_model->add_document({
        issuing_country => 'br',
        number          => '123.456.789-33',
        type            => 'cpf'
    });

    $client->address_line_1('Fake St 123');
    $client->address_line_2('apartamento 22');
    $client->address_postcode('12345900');
    $client->residence('br');
    $client->first_name('John');
    $client->last_name('Doe');
    $client->date_of_birth('1988-02-12');
    $client->save();

    $resp = Future->done(
        HTTP::Response->new(
            200, undef, undef,
            encode_json_utf8({
                    status   => 'pass',
                    messages => [],
                    report   => {birthdate => "1988-02-12"}})));

    ok $idv_event_handler->($args)->get, 'the event processed without error';

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
            'id'                       => '9',
            'document_type'            => 'cpf'
        },
        'Document has refuted from pass -  status name mismatch'
    );

};

subtest 'testing pass status and underage' => sub {
    my $idv_event_handler = BOM::Event::Process->new(category => 'generic')->actions->{identity_verification_requested};

    my $email = 'test_verify_pass+underage@binary.com';
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
    $updates  = 0;
    @requests = ();

    $idv_model->add_document({
        issuing_country => 'br',
        number          => '123.456.789-33',
        type            => 'cpf'
    });

    $client->address_line_1('Fake St 123');
    $client->address_line_2('apartamento 22');
    $client->address_postcode('12345900');
    $client->residence('br');
    $client->first_name('John');
    $client->last_name('Doe');
    $client->date_of_birth('2005-02-12');
    $client->save();

    $resp = Future->done(
        HTTP::Response->new(
            200, undef, undef,
            encode_json_utf8({
                    status   => 'pass',
                    messages => [],
                    report   => {
                        full_name => "John Doe",
                        birthdate => "2005-02-12"
                    }})));

    ok $idv_event_handler->($args)->get, 'the event processed without error';

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
            'id'                       => '10',
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
    $updates  = 0;
    @requests = ();

    $idv_model->add_document({
        issuing_country => 'br',
        number          => '123.456.789-33',
        type            => 'cpf',
    });

    $client->address_line_1('Fake St 123');
    $client->address_line_2('apartamento 22');
    $client->address_postcode('12345900');
    $client->residence('br');
    $client->first_name('John');
    $client->last_name('Doe');
    $client->date_of_birth('2005-02-12');
    $client->save();

    $resp = Future->done(
        HTTP::Response->new(
            200, undef, undef,
            encode_json_utf8({
                    status   => 'refuted',
                    messages => ['EXPIRED'],
                    report   => {
                        full_name   => "John Doe",
                        birthdate   => "2005-02-12",
                        expiry_date => "2009-05-12",
                    }})));

    ok $idv_event_handler->($args)->get, 'the event processed without error';

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
            'id'                       => '11',
            'document_type'            => 'cpf'
        },
        'Document has refuted from pass -  status underage'
    );

};

subtest 'testing refuted status and dob mismatch' => sub {
    my $idv_event_handler = BOM::Event::Process->new(category => 'generic')->actions->{identity_verification_requested};

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
    $updates  = 0;
    @requests = ();

    $idv_model->add_document({
        issuing_country => 'br',
        number          => '123.456.789-33',
        type            => 'cpf',
    });

    $client->address_line_1('Fake St 123');
    $client->address_line_2('apartamento 22');
    $client->address_postcode('12345900');
    $client->residence('br');
    $client->first_name('John');
    $client->last_name('Doe');
    $client->date_of_birth('1996-02-12');
    $client->save();

    $resp = Future->done(
        HTTP::Response->new(
            200, undef, undef,
            encode_json_utf8({
                    status   => 'refuted',
                    messages => ['DOB_MISMATCH'],
                    report   => {
                        full_name => "John Doe",
                        birthdate => "1997-03-12",
                    }})));

    ok $idv_event_handler->($args)->get, 'the event processed without error';

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
            'id'                       => '12',
            'document_type'            => 'cpf'
        },
        'Document has refuted from pass -  status underage'
    );

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
    $updates  = 0;
    @requests = ();

    $idv_model->add_document({
        issuing_country => 'br',
        number          => '123.456.789-33',
        type            => 'cpf',
    });

    $client->address_line_1('Fake St 123');
    $client->address_line_2('apartamento 22');
    $client->address_postcode('12345900');
    $client->residence('br');
    $client->first_name('John');
    $client->last_name('Doe');
    $client->date_of_birth('1996-02-12');
    $client->save();

    $resp = Future->done(
        HTTP::Response->new(
            200, undef, undef,
            encode_json_utf8({
                    status   => 'refuted',
                    messages => ['NAME_MISMATCH'],
                    report   => {
                        full_name => "John Mary Doe",

                    }})));

    ok $idv_event_handler->($args)->get, 'the event processed without error';

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
            'id'                       => '13',
            'document_type'            => 'cpf'
        },
        'Document has refuted from pass -  status underage'
    );

};

subtest 'testing callback status' => sub {
    my $idv_event_handler = BOM::Event::Process->new(category => 'generic')->actions->{identity_verification_processed};

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
        loginid  => $client->loginid,
        status   => 'callback',
        response => {},
        message  => [],
    };

    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->user->id);
    $updates  = 0;
    @requests = ();

    $idv_model->add_document({
        issuing_country => 'br',
        number          => '123.456.789-99',
        type            => 'cpf'
    });

    $client->address_line_1('Fake St 123');
    $client->address_line_2('apartamento 22');
    $client->address_postcode('12345900');
    $client->residence('br');
    $client->first_name('John');
    $client->last_name('Doe');
    $client->date_of_birth('1988-02-12');
    $client->save();

    ok $idv_event_handler->($args)->get, 'the event processed without error';

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

subtest 'testing connection refused' => sub {
    my $idv_event_handler = BOM::Event::Process->new(category => 'generic')->actions->{identity_verification_requested};

    my $email = 'test_verify_connection_refused@binary.com';
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
    $updates  = 0;
    @requests = ();

    $idv_model->add_document({
        issuing_country => 'br',
        number          => '123.456.789-33',
        type            => 'cpf'
    });

    $client->address_line_1('Fake St 123');
    $client->address_line_2('apartamento 22');
    $client->address_postcode('12345900');
    $client->residence('br');
    $client->first_name('John');
    $client->last_name('Doe');
    $client->date_of_birth('1988-02-12');
    $client->save();

    $resp = Future->fail('connection refused');

    my $previous_submissions = $redis->get('IDV::REQUEST::PER::USER::' . $client->binary_user_id) // 0;

    ok $idv_event_handler->($args)->get, 'the event processed without error';

    my $document = $idv_model->get_last_updated_document;

    cmp_deeply(
        $document,
        {
            'document_number'          => '123.456.789-33',
            'status'                   => 'failed',
            'document_expiration_date' => undef,
            'is_checked'               => 1,
            'issuing_country'          => 'br',
            'status_messages'          => '["CONNECTION_REFUSED"]',
            'id'                       => $document->{id},
            'document_type'            => 'cpf'
        },
        'Document has unavailable status'
    );

    my $current_submissions = $redis->get('IDV::REQUEST::PER::USER::' . $client->binary_user_id);

    is $current_submissions, $previous_submissions, 'Submissions should be reset';

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
    $updates  = 0;
    @requests = ();

    $idv_model->add_document({
        issuing_country => 'br',
        number          => '123.456.789-33',
        type            => 'cpf'
    });

    $client->address_line_1('Fake St 123');
    $client->address_line_2('apartamento 22');
    $client->address_postcode('12345900');
    $client->residence('br');
    $client->first_name('John');
    $client->last_name('Doe');
    $client->date_of_birth('1988-02-12');
    $client->save();

    $resp = Future->fail('UNEXPECTED ERROR');

    ok $idv_event_handler->($args)->get, 'the event processed without error';

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
            'id'                       => $document->{id},
            'document_type'            => 'cpf'
        },
        'Document has unavailable status'
    );

    $log->contains_ok(qr/Unhandled IDV exception: UNEXPECTED ERROR/, "good message was logged");

};

sub _reset_submissions {
    my $user_id = shift;
    my $redis   = BOM::Config::Redis::redis_events();

    $redis->set(BOM::User::IdentityVerification::IDV_REQUEST_PER_USER_PREFIX . $user_id, 0);
}

done_testing();
