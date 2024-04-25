use strict;
use warnings;

use Test::More;
use Log::Any::Test;
use Log::Any qw($log);
use Test::MockModule;
use Test::Deep;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::Platform::Token::API;
use BOM::Test::RPC::QueueClient;
use BOM::Test::Helper::Client;
use BOM::User;
use BOM::Config::Runtime;
use BOM::Config::Redis;

my $c = BOM::Test::RPC::QueueClient->new();

my $user = BOM::User->create(
    email    => 'example@binary.com',
    password => 'test_passwd'
);

my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    binary_user_id => $user->id
});

$user->add_client($client_cr);
$client_cr->user($user);
$client_cr->binary_user_id($user->id);
$client_cr->save;

my $token_model = BOM::Platform::Token::API->new;
my $token_cr    = $token_model->create_token($client_cr->loginid, 'test token');

my $pnv = $user->pnv;
my $next_attempt;
my $generate_otp;
my $verified;
my $increase_attempts;

my $pnv_mock = Test::MockModule->new(ref($pnv));
$pnv_mock->mock(
    'next_attempt',
    sub {
        return $next_attempt;
    });

$pnv_mock->mock(
    'verified',
    sub {
        return $verified;
    });

$pnv_mock->mock(
    'generate_otp',
    sub {
        $generate_otp = 1;

        return 'mocked';
    });

$pnv_mock->mock(
    'increase_attempts',
    sub {
        $increase_attempts = 1;

        return 1;
    });

my $params = {
    token    => $token_cr,
    language => 'EN',
    args     => {
        carrier => 'whastapp',
    }};

subtest 'Already verified' => sub {
    $verified          = 1;
    $next_attempt      = 0;
    $increase_attempts = undef;

    $c->call_ok('phone_number_challenge', $params)
        ->has_no_system_error->has_error->error_code_is('AlreadyVerified', 'the account is already verified');

    is $increase_attempts, 1, 'attempts increased';
};

subtest 'No attempts left' => sub {
    $verified          = 0;
    $next_attempt      = time + 1000000;
    $increase_attempts = undef;

    $c->call_ok('phone_number_challenge', $params)->has_no_system_error->has_error->error_code_is('NoAttemptsLeft', 'No attempts left');

    is $increase_attempts, 1, 'attempts increased';
};

subtest 'Generate a valid OTP' => sub {
    $log->clear();

    $next_attempt = time;

    $increase_attempts = undef;

    my $res = $c->call_ok('phone_number_challenge', $params)->has_no_system_error->has_no_error->result;

    is $res, 1, 'Expected result';

    is $generate_otp, 1, 'generate otp called';

    my $phone = $client_cr->phone;

    cmp_deeply $log->msgs(),
        [{
            category => 'BOM::RPC::v3::PhoneNumberVerification',
            level    => 'debug',
            message  => "Sending OTP mocked to $phone, via whastapp",
        }
        ],
        'expected log generated';

    is $increase_attempts, 1, 'attempts increased';
};

$pnv_mock->unmock_all();

done_testing();
