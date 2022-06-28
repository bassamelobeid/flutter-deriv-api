use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::Deep;

use Date::Utility;
use Future::Exception;
use HTTP::Response;
use JSON::MaybeUTF8 qw(encode_json_utf8 decode_json_utf8);

use BOM::Config::Redis;
use BOM::Event::Process;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::User::IdentityVerification;

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

my $mock_idv_event_action = Test::MockModule->new('BOM::Event::Actions::Client::IdentityVerification');
$mock_idv_event_action->mock('_is_microservice_available', 1);

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
    });                                # prevent making real calls

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

my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->user->id);

my $idv_event_handler = BOM::Event::Process->new(category => 'generic')->actions->{identity_verification_requested};

subtest 'verify identity by smile_identity through microservice is passed and data are valid' => sub {
    $args = {
        loginid => $client->loginid,
    };

    $updates = 0;

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
                    status        => 'pass',
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
    ok $client->status->age_verification, 'age verified correctly';

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
    ok $client->status->age_verification, 'age verified correctly';
    ok $client->fully_authenticated(), 'client is fully authenticated';
    is $client->get_authentication('IDV')->{status}, 'pass', 'PoA with IDV';
    ok !$client->status->unwelcome, 'client unwelcome is removed';

    is $mock_idv_status, 'verified', 'verify_identity returns `verified` status';
};

subtest 'microservice is unavailable' => sub {
    $resp = Future->done(HTTP::Response->new(200, undef, undef, undef));

    $idv_model->add_document({
        issuing_country => 'ng',
        number          => '99989',
        type            => 'dl'
    });

    ok $idv_event_handler->($args)->get, 'the event processed without error';

    my $doc  = $idv_model->get_last_updated_document();
    my $msgs = decode_json_utf8 $doc->{status_messages};

    is_deeply $msgs, ['UNAVAILABLE_MICROSERVICE'], 'message is correct';
};

sub _reset_submissions {
    my $user_id = shift;
    my $redis   = BOM::Config::Redis::redis_events();

    $redis->set(BOM::User::IdentityVerification::IDV_REQUEST_PER_USER_PREFIX . $user_id, 0);
}

done_testing();
