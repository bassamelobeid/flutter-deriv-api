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
my $uid = $user->id;

my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    email          => 'example@binary.com',
    binary_user_id => $uid
});

$user->add_client($client_cr);
$client_cr->user($user);
$client_cr->binary_user_id($uid);
$client_cr->save;

my $token_model = BOM::Platform::Token::API->new;
my $token_cr    = $token_model->create_token($client_cr->loginid, 'test token');

my $pnv = $user->pnv;
my $next_attempt;
my $generate_otp;
my $verified;
my $increase_attempts;
my $clear_attempts;
my $clear_verify_attempts;
my $email_code = 'nada';

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

$pnv_mock->mock(
    'clear_verify_attempts',
    sub {
        $clear_verify_attempts = 1;

        return 1;
    });

$pnv_mock->mock(
    'clear_attempts',
    sub {
        $clear_attempts = 1;

        return 1;
    });

$pnv_mock->mock(
    'email_blocked',
    sub {
        return undef;
    });

my $params = {
    token    => $token_cr,
    language => 'EN',
    args     => {
        carrier    => 'whastapp',
        email_code => $email_code,
    }};

$pnv_mock->mock(
    'clear_verify_attempts',
    sub {
        $clear_verify_attempts = 1;

        return 1;
    });

$pnv_mock->mock(
    'clear_attempts',
    sub {
        $clear_attempts = 1;

        return 1;
    });

subtest 'Invalid Email Code' => sub {
    $verified          = 0;
    $next_attempt      = 0;
    $increase_attempts = undef;
    $c->call_ok('phone_number_challenge', $params)->has_no_system_error->has_error->error_code_is('InvalidToken', 'invalid token!');

    is $increase_attempts, 1, 'attempts increased';
};

subtest 'Already verified' => sub {
    $verified = 0;
    generate_email_code();
    $verified              = 1;
    $next_attempt          = 0;
    $clear_attempts        = undef;
    $increase_attempts     = undef;
    $clear_verify_attempts = undef;

    $c->call_ok('phone_number_challenge', $params)
        ->has_no_system_error->has_error->error_code_is('AlreadyVerified', 'the account is already verified');

    is $increase_attempts,     undef, 'attempts increased';
    is $clear_attempts,        undef, 'attempts not cleared';
    is $clear_verify_attempts, undef, 'verify attempts not cleared';
};

subtest 'No attempts left' => sub {
    $verified = 0;
    generate_email_code();

    $next_attempt      = time + 1000000;
    $increase_attempts = undef;
    generate_email_code();

    $clear_attempts        = undef;
    $clear_verify_attempts = undef;

    $c->call_ok('phone_number_challenge', $params)->has_no_system_error->has_error->error_code_is('NoAttemptsLeft', 'No attempts left');

    is $increase_attempts,     1,     'attempts increased';
    is $clear_attempts,        undef, 'attempts not cleared';
    is $clear_verify_attempts, undef, 'verify attempts not cleared';
};

subtest 'Generate a valid OTP' => sub {
    $verified = 0;
    generate_email_code();

    $log->clear();

    $generate_otp = undef;

    $next_attempt = time;

    $increase_attempts = undef;

    $clear_attempts = undef;

    $clear_verify_attempts = undef;

    my $res = $c->call_ok('phone_number_challenge', $params)->has_no_system_error->has_no_error->result;

    is $res, 1, 'Expected result';

    is $generate_otp, 1, 'generate otp called';

    my $phone = $client_cr->phone;

    cmp_deeply $log->msgs(),
        [{
            category => 'BOM::RPC::v3::PhoneNumberVerification',
            level    => 'debug',
            message  => "Sending OTP mocked to $phone, via whastapp, for user $uid",
        }
        ],
        'expected log generated';

    is $increase_attempts,     1,     'attempts increased';
    is $clear_attempts,        undef, 'attempts not cleared';
    is $clear_verify_attempts, 1,     'verify attempts cleared';

    subtest 'try to generate an OTP again' => sub {
        $verified = 0;
        generate_email_code();

        $log->clear();

        $generate_otp = undef;

        $next_attempt = time;

        $increase_attempts = undef;

        $clear_attempts = undef;

        $clear_verify_attempts = undef;

        my $res = $c->call_ok('phone_number_challenge', $params)->has_no_system_error->has_no_error->result;

        is $res, 1, 'Expected result';

        is $generate_otp, 1, 'generate otp called';

        cmp_deeply $log->msgs(),
            [{
                category => 'BOM::RPC::v3::PhoneNumberVerification',
                level    => 'debug',
                message  => "Sending OTP mocked to $phone, via whastapp, for user $uid",
            }
            ],
            'expected log generated';

        is $increase_attempts,     1,     'attempts increased';
        is $clear_attempts,        undef, 'attempts not cleared';
        is $clear_verify_attempts, 1,     'verify attempts cleared';
    };
};

$pnv_mock->unmock_all();

sub generate_email_code {
    my $redis = BOM::Config::Redis::redis_events_write();

    $redis->del(+BOM::User::PhoneNumberVerification::PNV_NEXT_EMAIL_PREFIX . $user->id);

    # create the token
    my @emitted;
    no warnings 'redefine';
    local *BOM::Platform::Event::Emitter::emit = sub { push @emitted, @_ };

    my $verify_email_params = {
        token    => $token_cr,
        language => 'EN',
        args     => {
            verify_email => $client_cr->email,
            type         => 'phone_number_verification',
            language     => 'EN',
        }};

    $c->call_ok('verify_email', $verify_email_params)->has_no_system_error->has_no_error->result_is_deeply({
            stash => {
                app_markup_percentage      => 0,
                valid_source               => 1,
                source_bypass_verification => 0,
                source_type                => 'official',
            },
            status => 1
        },
        "It always should return 1, so not to leak client's email"
    );

    my (undef, $emission_args) = @emitted;

    $email_code = $emission_args->{properties}->{code};

    ok $email_code, 'there is an email code';

    $params->{args}->{email_code} = $email_code;
}

done_testing();
