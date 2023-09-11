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
use JSON::MaybeUTF8 qw(encode_json_utf8 decode_json_utf8 decode_json_text);

use BOM::Config::Redis;
use BOM::Event::Process;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use BOM::User::IdentityVerification;
use BOM::Event::Actions::Client::IdentityVerification;
use BOM::Database::UserDB;

use constant IDV_LOCK_PENDING => 'IDV::LOCK::PENDING::';

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
my @urls;
my @options;
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
        shift;
        push @urls,     shift;    # request url
        push @requests, shift;    # request body
        push @options,  +{@_};    # the rest of the params are the options

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
        type            => 'national_id',
        additional      => 'topside',
    });

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

    $resp = Future->done(
        HTTP::Response->new(
            200, undef, undef,
            encode_json_utf8({
                    status => 'verified',
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
            additional      => 'topside',
        },
        profile => {
            id         => 'CR10000',
            first_name => 'John',
            last_name  => 'Doe',
            birthdate  => '1988-02-12',
        },
        address => {
            line_1    => 'Fake St 123',
            line_2    => 'apartamento 22',
            postcode  => '12345900',
            residence => 'ar',
            city      => 'fake'
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
            id         => $client->loginid,
            first_name => 'John',
            last_name  => 'Doe',
            birthdate  => '1988-02-12',
        },
        address => {
            line_1    => 'Fake St 123',
            line_2    => 'apartamento 22',
            postcode  => '12345900',
            residence => 'br',
            city      => 'Beverly Hills',
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

    my $doc = $idv_model->get_last_updated_document();

    cmp_deeply $doc->{status_messages}, encode_json_utf8(['ADDRESS_VERIFIED']), 'expected messages stored';
};

subtest 'microservice is unavailable' => sub {
    $resp = Future->done(HTTP::Response->new(200, undef, undef, undef));

    $encoding = {};
    $idv_model->add_document({
        issuing_country => 'ng',
        number          => '99989',
        type            => 'dl'
    });

    my $redis = BOM::Config::Redis::redis_events();
    $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 1);

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

    my $doc = $idv_model->get_last_updated_document();

    cmp_deeply $doc->{status_messages}, encode_json_utf8(['ADDRESS_VERIFIED']), 'expected messages stored';
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

    ok $error=~ /No submissions left, IDV request has ignored for loginid: CR10004/, 'expected exception caught no submissions';

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

    ok $error=~ /No status received./, 'expected exception caught no status added';

    $args->{status} = 'verified';

    $error = exception {
        $idv_event_handler->($args)->get;
    };

    ok $error=~ /Could not initiate client for loginid: CR0/, 'expected exception caught';

    $args->{loginid} = $client->loginid;

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

    $error = exception {
        $idv_event_handler->($args)->get;
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
    $updates  = 0;
    @requests = ();

    $idv_model->add_document({
        issuing_country => 'br',
        number          => '123.456.789-33',
        type            => 'cpf'
    });

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
    $updates  = 0;
    @requests = ();

    $idv_model->add_document({
        issuing_country => 'br',
        number          => '123.456.789-33',
        type            => 'cpf'
    });

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
            'id'                       => re('\d+'),
            'document_type'            => 'cpf'
        },
        'Document has unavailable status'
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

    my $current_submissions = $idv_model->submissions_left;

    $idv_model->add_document({
        issuing_country => 'br',
        number          => '123.456.789-33',
        type            => 'cpf',
    });

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

    $client->status->set('age_verification', 'staff', 'age verified manually');

    ok $idv_event_handler->($args)->get, 'the event processed without error';

    ok !$client->status->age_verification, 'age verification was cleared';

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

    my $current_submissions = $idv_model->submissions_left;

    $idv_model->add_document({
        issuing_country => 'br',
        number          => '123.456.789-33',
        type            => 'cpf',
    });

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

    $client->status->set('age_verification', 'staff', 'age verified manually');

    ok $idv_event_handler->($args)->get, 'the event processed without error';

    ok !$client->status->age_verification, 'age verification was cleared';

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

    subtest 'fixing DOB mismatch + metric' => sub {
        my $idv_fixing_handler = BOM::Event::Process->new(category => 'generic')->actions->{poi_check_rules};
        my $dog_mock           = Test::MockModule->new('DataDog::DogStatsd::Helper');
        my @metrics;

        my $client_mock = Test::MockModule->new('BOM::Event::Actions::Client');

        $dog_mock->mock(
            'stats_inc',
            sub {
                push @metrics, @_ if scalar @_ == 2;
                push @metrics, @_, undef if scalar @_ == 1;

                return 1;
            });

        # test for the case where the json decode fails/provider does not return a report
        my $json_calls = 0;
        $client_mock->mock(
            'decode_json_text',
            sub {
                $json_calls++;

                die '1st JSON decode throw' if $json_calls == 1;

                return $client_mock->original('decode_json_text')->(@_);
            });

        $idv_fixing_handler->($args)->get;

        is $json_calls, 2, 'two json calls';

        $client = BOM::User::Client->new({loginid => $client->loginid});

        ok $client->status->poi_dob_mismatch,  'dob mismatch remains';
        ok !$client->status->age_verification, 'client is still not age verified';

        $document = $idv_model->get_last_updated_document;
        is $document->{status}, 'refuted', 'document is still refuted';

        cmp_deeply [@metrics], [], 'No dd metrics json decode failed';

        @metrics    = ();
        $json_calls = 0;

        $client_mock->unmock('decode_json_text');

        # test for the case where the 2nd json decode fails/no messages passed to idv_rules
        $client_mock->mock(
            'decode_json_text',
            sub {
                $json_calls++;

                die '2nd JSON decode throw' if $json_calls > 1;

                return $client_mock->original('decode_json_text')->(@_);
            });

        $idv_fixing_handler->($args)->get;

        is $json_calls, 2, 'two json calls';

        $client = BOM::User::Client->new({loginid => $client->loginid});

        ok $client->status->poi_dob_mismatch,  'dob mismatch remains';
        ok !$client->status->age_verification, 'client is still not age verified';

        $document = $idv_model->get_last_updated_document;
        is $document->{status},          'refuted',          'document is still refuted';
        is $document->{status_messages}, '["DOB_MISMATCH"]', 'messages is populated with error reason';

        cmp_deeply [@metrics],
            [
            'event.idv.client_verification.result' => {tags => ['result:dob_mismatch']},
            ],
            'Expected dd metrics dob mismatch';

        @metrics = ();

        $client_mock->unmock('decode_json_text');
        # test consequences of coalescing into empty messages, something like messages yes: auth by idv and messages no: auth by idv_photo

        # test the case where rules are called correctly but still there is a mismatch
        $idv_fixing_handler->($args)->get;

        $client = BOM::User::Client->new({loginid => $client->loginid});

        ok $client->status->poi_dob_mismatch,  'dob mismatch remains';
        ok !$client->status->age_verification, 'client is still not age verified';

        $document = $idv_model->get_last_updated_document;
        is $document->{status}, 'refuted', 'document is still refuted';

        cmp_deeply [@metrics],
            [
            'event.idv.client_verification.result' => {tags => ['result:dob_mismatch']},
            ],
            'Expected dd metrics dob mismatch';

        @metrics = ();

        # now clients details are corrected
        $client->date_of_birth('1997-03-12');
        $client->save();

        $idv_fixing_handler->($args)->get;

        $client = BOM::User::Client->new({loginid => $client->loginid});

        ok !$client->status->poi_dob_mismatch, 'dob mismatch status is gone';
        ok $client->status->age_verification,  'client is now age verified';

        $document = $idv_model->get_last_updated_document;
        is $document->{status}, 'verified', 'document is now also verified';

        is !$client->authentication_status, '', 'Messages is empty';
        ok !$client->fully_authenticated, 'Client is not fully auth';

        cmp_deeply [@metrics],
            [
            'event.idv.client_verification.result' => {tags => ['result:age_verified_corrected']},
            ],
            'Expected dd metrics for verfied result';

        $dog_mock->unmock_all;
        $client_mock->unmock_all;
    }

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

    my $current_submissions = $idv_model->submissions_left;

    $idv_model->add_document({
        issuing_country => 'br',
        number          => '123.456.789-33',
        type            => 'cpf',
    });

    my $redis = BOM::Config::Redis::redis_events();
    $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 1);

    $client->address_line_1('Fake St 123');
    $client->address_line_2('apartamento 22');
    $client->address_postcode('12345900');
    $client->residence('br');
    $client->first_name('John');
    $client->last_name('Foe');
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
                        birthdate => '1996-02-12',
                    }})));

    ok $idv_event_handler->($args)->get, 'the event processed without error';

    ok $client->status->poi_name_mismatch, 'POI name mismatch status applied properly';

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

    subtest 'fixing name mismatch + metric' => sub {
        my $idv_fixing_handler = BOM::Event::Process->new(category => 'generic')->actions->{poi_check_rules};
        my $dog_mock           = Test::MockModule->new('DataDog::DogStatsd::Helper');
        my @metrics;

        $dog_mock->mock(
            'stats_inc',
            sub {
                push @metrics, @_ if scalar @_ == 2;
                push @metrics, @_, undef if scalar @_ == 1;

                return 1;
            });

        $idv_fixing_handler->($args)->get;

        $client = BOM::User::Client->new({loginid => $client->loginid});

        ok $client->status->poi_name_mismatch, 'name mismatch remains';
        ok !$client->status->age_verification, 'client is still not age verified';

        $document = $idv_model->get_last_updated_document;
        is $document->{status}, 'refuted', 'document is still refuted';

        cmp_deeply [@metrics],
            [
            'event.idv.client_verification.result' => {tags => ['result:name_mismatch']},
            ],
            'Expected dd metrics name mismatch';

        @metrics = ();

        # now clients details are corrected
        $client->first_name('John Mary');
        $client->last_name('Doe');
        $client->save();

        $idv_fixing_handler->($args)->get;

        $client = BOM::User::Client->new({loginid => $client->loginid});

        ok !$client->status->poi_name_mismatch, 'name mismatch status is gone';
        ok $client->status->age_verification,   'client is now age verified';

        $document = $idv_model->get_last_updated_document;
        is $document->{status}, 'verified', 'document is now also verified';

        cmp_deeply [@metrics],
            [
            'event.idv.client_verification.result' => {tags => ['result:age_verified_corrected']},
            ],
            'Expected dd metrics for verfied result';

        $dog_mock->unmock_all;
    }
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
            $updates  = 0;
            @requests = ();

            $idv_model->add_document({
                issuing_country => 'br',
                number          => '123.456.789-33',
                type            => 'cpf',
            });

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

            $resp = Future->done(
                HTTP::Response->new(
                    200, undef, undef,
                    encode_json_utf8({
                            status   => 'refuted',
                            messages => ['NAME_MISMATCH'],
                            report   => {
                                full_name => "John Mary Doe",
                                $what     => "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==",
                            }})));

            ok $idv_event_handler->($args)->get, 'the event processed without error';

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
                'Document has refuted from pass -  status underage'
            );

            my ($photo) = $check->@*;

            my ($doc) = $client->find_client_authentication_document(query => [id => $photo->{photo_id}]);

            is $doc->{status},          'rejected', 'status in BO reflects idv status - rejected';
            is $doc->{issuing_country}, 'br',       'issuing country is correctly populated';
        };

        subtest "testing $what being sent as parameter - verified" => sub {
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
            $updates  = 0;
            @requests = ();

            $idv_model->add_document({
                issuing_country => 'br',
                number          => '123.456.789-33',
                type            => 'cpf',
            });

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

            $resp = Future->done(
                HTTP::Response->new(
                    200, undef, undef,
                    encode_json_utf8({
                            status   => 'verified',
                            messages => ['NAME_MISMATCH'],
                            report   => {
                                full_name => "John Mary Doe",
                                $what     => "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==",
                            }})));

            ok $idv_event_handler->($args)->get, 'the event processed without error';

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

            $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 1);

            $idv_model->add_document({
                issuing_country => 'br',
                number          => '123.456.789-34',
                type            => 'cpf',
            });

            ok $idv_event_handler->($args)->get, 'the event processed without error';

            my $check_two = $dbic->run(
                fixup => sub {
                    $_->selectall_arrayref("SELECT photo_id FROM idv.document_check where document_id = ?", {Slice => {}}, $document->{id});
                });

            cmp_deeply $check , $check_two, 'photo id returned is the same';

            my ($photo) = $check->@*;

            my ($doc) = $client->find_client_authentication_document(query => [id => $photo->{photo_id}]);

            is $doc->{status},          'verified', 'status in BO reflects idv status - verified';
            is $doc->{origin},          'idv',      'IDV is the origin of the doc';
            is $doc->{issuing_country}, 'br',       'issuing country is correctly popualted';
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
        $updates  = 0;
        @requests = ();

        $idv_model->add_document({
            issuing_country => 'br',
            number          => '123.456.789-33',
            type            => 'cpf',
        });

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

        $resp = Future->done(
            HTTP::Response->new(
                200, undef, undef,
                encode_json_utf8({
                        status   => 'verified',
                        messages => ['NAME_MISMATCH'],
                        report   => {
                            full_name => "John Mary Doe",
                            selfie    => 'iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAAD0lEQVR42mNk+P+/ngEIAA+AAn9nd0gSAAAAAElFTkSuQmCC',
                            document  => "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==",
                        }})));

        ok $idv_event_handler->($args)->get, 'the event processed without error';

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

        $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 1);

        $idv_model->add_document({
            issuing_country => 'br',
            number          => '123.456.789-34',
            type            => 'cpf',
        });

        ok $idv_event_handler->($args)->get, 'the event processed without error';

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
        ok $client->fully_authenticated, 'Fully auth';

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

    $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 1);

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
            'id'                       => re('\d+'),
            'document_type'            => 'cpf'
        },
        'Document has unavailable status'
    );

    my $current_submissions = $redis->get('IDV::REQUEST::PER::USER::' . $client->binary_user_id);

    is $current_submissions, $previous_submissions - 1, 'Submissions should be reset';

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

    $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 1);

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
            'id'                       => re('\d+'),
            'document_type'            => 'cpf'
        },
        'Document has unavailable status'
    );

    $log->contains_ok(qr/Unhandled IDV exception: UNEXPECTED ERROR/, "good message was logged");

};

subtest 'unit test - idv_webhook_relay' => sub {

    my $idv_event_handler = BOM::Event::Process->new(category => 'generic')->actions->{idv_webhook_received};

    @requests = ();
    @options  = ();
    @urls     = ();

    subtest 'sus callback' => sub {
        $log->clear();

        my $data = BOM::Event::Actions::Client::IdentityVerification::idv_webhook_relay({
                data => {
                    json => {
                        test => 1,
                    }
                },
                headers => {'x-sus-header' => '1234'}})->get;

        $log->contains_ok(qr/no recognizable headers/, 'expected message was logged');

        cmp_bag([@urls],     [], 'no URL returned');
        cmp_bag([@requests], [], 'no request body returned');
        cmp_bag([@options],  [], 'no request body returned');
    };

    subtest 'MetaMap callback' => sub {
        $log->clear();

        my $data = BOM::Event::Actions::Client::IdentityVerification::idv_webhook_relay({
                data => {
                    json => {
                        test => 1,
                    }
                },
                headers => {'x-request-id' => '1234'}})->get;

        cmp_bag([@urls],     ['http://dummy:8080/v1/idv/webhook'], 'Expected URL returned');
        cmp_bag([@requests], ['{"test":1}'],                       'Expected request body returned');
        cmp_bag(
            [@options],
            [{
                    'content_type' => 'application/json',
                    'headers'      => {'x-request-id' => '1234'}}
            ],
            'Expected request body returned'
        );

        $log->clear();
        @urls     = ();
        @requests = ();
        @options  = ();
    };

    subtest 'Retry Mechanism callback' => sub {
        $idv_mock->mock(
            'verify_process',
            sub {
                return Future->done(1);
            });

        my $data = BOM::Event::Actions::Client::IdentityVerification::idv_webhook_relay({
                data => {
                    json => {
                        test => 1,
                    }
                },
                headers => {'x-retry-attempts' => '1'}})->get;

        cmp_deeply([@urls], [], 'Expected empty urls (no HTTP request made)');

        $log->contains_ok(qr/Got IDV webhook with attempt number: 1/, 'Expected log found');
        $log->contains_ok(qr/no req_echo/,                            'Expected log found');

        @urls = ();
        $log->clear();

        $data = BOM::Event::Actions::Client::IdentityVerification::idv_webhook_relay({
                data => {
                    json => {
                        req_echo => 1,
                    }
                },
                headers => {'x-retry-attempts' => '1'}})->get;

        cmp_deeply([@urls], [], 'Expected empty urls (no HTTP request made)');

        $log->contains_ok(qr/Got IDV webhook with attempt number: 1/, 'Expected log found');
        $log->does_not_contain_ok(qr/no req_echo/, 'Expected log not found');

        $log->clear();
        $idv_mock->unmock_all();
    };

    subtest 'Case Insensitive callback' => sub {
        $idv_mock->mock(
            'verify_process',
            sub {
                return Future->done(1);
            });

        @urls = ();
        $log->clear();

        my $data = BOM::Event::Actions::Client::IdentityVerification::idv_webhook_relay({
                data => {
                    json => {
                        req_echo => 1,
                    }
                },
                headers => {'X-ReTry-AttemPts' => '1'}})->get;

        cmp_deeply([@urls], [], 'Expected empty urls (no HTTP request made)');

        $log->contains_ok(qr/Got IDV webhook with attempt number: 1/, 'Expected log found');
        $log->does_not_contain_ok(qr/no req_echo/, 'Expected log not found');

        $log->clear();
        $idv_mock->unmock_all();
    }
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

subtest 'testing photo being sent as parameter - undef file type' => sub {
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
    $updates  = 0;
    @requests = ();

    $idv_model->add_document({
        issuing_country => 'br',
        number          => '666.456.789-33',
        type            => 'cpf',
    });

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

    $resp = Future->done(
        HTTP::Response->new(
            200, undef, undef,
            encode_json_utf8({
                    status   => 'verified',
                    messages => ['NAME_MISMATCH'],
                    report   => {
                        full_name => "John Mary Doe",
                        photo     => "Not Available",
                    }})));

    ok $idv_event_handler->($args)->get, 'the event processed without error';

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
    $updates  = 0;
    @requests = ();

    $idv_model->add_document({
        issuing_country => 'qq',
        number          => 'A000000000',
        type            => 'passport',
    });

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

    $resp = Future->done(
        HTTP::Response->new(
            200, undef, undef,
            encode_json_utf8({
                    status        => 'pending',
                    messages      => [],
                    response_body => {
                        full_name => "John Doe",
                        birthdate => "1997-03-12",
                    },
                    report => {
                        full_name => "John Doe",
                        birthdate => "1997-03-12",
                    }})));

    ok $idv_event_handler->($args)->get, 'the event processed without error';

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

sub _reset_submissions {
    my $user_id = shift;
    my $redis   = BOM::Config::Redis::redis_events();

    $redis->set(BOM::User::IdentityVerification::IDV_REQUEST_PER_USER_PREFIX . $user_id, 0);
}

done_testing();
