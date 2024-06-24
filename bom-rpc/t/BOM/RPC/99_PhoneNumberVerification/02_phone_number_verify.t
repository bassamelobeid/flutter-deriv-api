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
use BOM::Test::Customer;
use BOM::User;
use BOM::User::PhoneNumberVerification;
use BOM::Config::Runtime;
use BOM::Config::Redis;

my $c = BOM::Test::RPC::QueueClient->new();

my $customer = BOM::Test::Customer->create({
        email    => 'example@binary.com',
        password => 'test_passwd',
    },
    [{
            name        => 'CR',
            broker_code => 'CR'
        },
    ]);

my $pnv = BOM::User::PhoneNumberVerification->new($customer->get_user_id(), $customer->get_user_service_context());

my $verify_blocked;
my $verify_otp;
my $verified;
my $increase_verify_attempts;
my $clear_verify_attempts;
my $valid_otp;

my $pnv_mock = Test::MockModule->new(ref($pnv));
$pnv_mock->mock(
    'verify_blocked',
    sub {
        return $verify_blocked;
    });

$pnv_mock->mock(
    'verified',
    sub {
        return $verified;
    });

$pnv_mock->mock(
    'verify_otp',
    sub {
        $verify_otp = 1;

        return $valid_otp;
    });

$pnv_mock->mock(
    'increase_verify_attempts',
    sub {
        $increase_verify_attempts = 1;

        return 1;
    });

$pnv_mock->mock(
    'clear_verify_attempts',
    sub {
        $clear_verify_attempts = 1;

        return 1;
    });

my $params = {
    token    => $customer->get_client_token('CR'),
    language => 'EN',
    args     => {
        otp => undef,
    }};

subtest 'Already verified' => sub {
    $verified                 = 1;
    $verify_blocked           = undef;
    $clear_verify_attempts    = undef;
    $increase_verify_attempts = undef;

    $c->call_ok('phone_number_verify', $params)->has_no_system_error->has_error->error_code_is('AlreadyVerified', 'the account is already verified');

    is $increase_verify_attempts, undef, 'attempts not increased';
    is $clear_verify_attempts,    undef, 'attempts not cleared';
};

subtest 'No attempts left' => sub {
    $verified                 = 0;
    $verify_blocked           = 1;
    $increase_verify_attempts = undef;
    $clear_verify_attempts    = undef;

    $c->call_ok('phone_number_verify', $params)->has_no_system_error->has_error->error_code_is('NoAttemptsLeft', 'No attempts left');

    is $increase_verify_attempts, 1,     'attempts increased';
    is $clear_verify_attempts,    undef, 'attempts not cleared';
};

subtest 'Invalid OTP' => sub {
    my $otp = 'abcdef';

    $params->{args}->{otp} = $otp;

    $log->clear();

    $valid_otp = undef;

    $verify_otp = undef;

    $verify_blocked = undef;

    $increase_verify_attempts = undef;

    $clear_verify_attempts = undef;

    $c->call_ok('phone_number_verify', $params)->has_no_system_error->has_error->error_code_is('InvalidOTP', 'The OTP is not valid');

    is $verify_otp, 1, 'verify otp called';

    cmp_deeply $log->msgs(),
        [{
            category => 'BOM::RPC::v3::PhoneNumberVerification',
            level    => 'debug',
            message  => "Verifying OTP $otp, for user " . $customer->get_user_id(),
        }
        ],
        'expected log generated';

    is $increase_verify_attempts, 1,     'attempts increased';
    is $clear_verify_attempts,    undef, 'attempts not cleared';
};

subtest 'Valid OTP' => sub {
    my $otp = '123456';

    $params->{args}->{otp} = $otp;

    $log->clear();

    $verified = undef;

    $valid_otp = 1;

    $verify_otp = undef;

    $verify_blocked = undef;

    $increase_verify_attempts = undef;

    $clear_verify_attempts = undef;

    my $res = $c->call_ok('phone_number_verify', $params)->has_no_system_error->has_no_error->result;

    is $res, 1, 'Expected result';

    is $verify_otp, 1, 'verify otp called';
    cmp_deeply $log->msgs(),
        [{
            category => 'BOM::RPC::v3::PhoneNumberVerification',
            level    => 'debug',
            message  => "Verifying OTP $otp, for user " . $customer->get_user_id(),
        }
        ],
        'expected log generated';

    is $increase_verify_attempts, 1, 'attempts increased';
    is $clear_verify_attempts,    1, 'attempts cleared';

    subtest 'try to verify an OTP again' => sub {
        $log->clear();

        $verified = 1;

        $valid_otp = 1;

        $verify_otp = undef;

        $verify_blocked = undef;

        $increase_verify_attempts = undef;

        $clear_verify_attempts = undef;

        $c->call_ok('phone_number_verify', $params)->has_no_system_error->has_error->error_code_is('AlreadyVerified', 'the user is already verified');

        is $verify_otp, undef, 'verify otp is not called again';

        cmp_deeply $log->msgs(), [], 'expected log generated (empty)';

        is $increase_verify_attempts, undef, 'attempts not increased';
        is $clear_verify_attempts,    undef, 'attempts not cleared';
    };
};

$pnv_mock->unmock_all();

done_testing();
