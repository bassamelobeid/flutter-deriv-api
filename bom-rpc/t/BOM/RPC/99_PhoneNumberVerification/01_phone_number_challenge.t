use strict;
use warnings;

use Test::More;
use Log::Any::Test;
use Log::Any qw($log);
use Test::MockModule;
use Test::Deep;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::Test::Customer;
use BOM::Platform::Token::API;
use BOM::Test::RPC::QueueClient;
use BOM::User;
use BOM::User::PhoneNumberVerification;
use BOM::Config::Runtime;
use BOM::Config::Redis;
use BOM::Service;

my $c = BOM::Test::RPC::QueueClient->new();

my $customer = BOM::Test::Customer->create({
        email    => 'example@binary.com',
        password => 'test_passwd',
    },
    [{
            name        => 'CR',
            broker_code => 'CR'
        },
        {
            name        => 'VR',
            broker_code => 'VRTC'
        },
    ],
);

my $pnv = BOM::User::PhoneNumberVerification->new($customer->get_user_id(), $customer->get_user_service_context());

my $next_attempt;
my $generate_otp;
my $verified;
my $increase_attempts;
my $clear_attempts;
my $clear_verify_attempts;
my $email_code = 'nada';
my $taken;
my $generate_otp_result = 1;
my $generate_otp_params = {
    carrier => undef,
    phone   => undef,
    lang    => undef,
};

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
        my (undef, $carrier, $phone, $lang) = @_;
        $generate_otp = 1;

        $generate_otp_params = {
            carrier => $carrier,
            phone   => $phone,
            lang    => $lang,
        };

        return $generate_otp_result;
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

$pnv_mock->mock(
    'is_phone_taken',
    sub {
        return $taken;
    });

my $params = {
    token    => $customer->get_client_token('CR'),
    language => 'EN',
    args     => {
        carrier    => 'whatsapp',
        email_code => $email_code,
    }};

$pnv_mock->mock(
    'clear_verify_attempts',
    sub {
        $clear_verify_attempts = 1;

        return 1;
    });

subtest 'Virtual challenge' => sub {
    my $params_vr = {
        token    => $customer->get_client_token('VR'),
        language => 'EN',
        args     => {
            carrier    => 'whatsapp',
            email_code => $email_code,
        }};

    $increase_attempts = undef;
    $c->call_ok('phone_number_challenge', $params_vr)->has_no_system_error->has_error->error_code_is('VirtualNotAllowed', 'invalid token!');

    is $increase_attempts, undef, 'attempts not increased';
};

subtest 'Invalid Email Code' => sub {
    $verified          = 0;
    $next_attempt      = 0;
    $increase_attempts = undef;
    $c->call_ok('phone_number_challenge', $params)->has_no_system_error->has_error->error_code_is('InvalidToken', 'virtual is not allowed!');

    is $increase_attempts, 1, 'attempts increased';
};

subtest 'Invalid Phone Number' => sub {
    my $client_cr = $customer->get_client_object('CR');
    $client_cr->phone('+++');
    $client_cr->save;

    $verified = 0;
    generate_email_code();
    $verified              = 0;
    $next_attempt          = 0;
    $clear_attempts        = undef;
    $increase_attempts     = undef;
    $clear_verify_attempts = undef;

    $c->call_ok('phone_number_challenge', $params)->has_no_system_error->has_error->error_code_is('InvalidPhone', 'invalid phone');

    is $increase_attempts,     undef, 'attempts increased';
    is $clear_attempts,        undef, 'attempts not cleared';
    is $clear_verify_attempts, undef, 'verify attempts not cleared';

    $client_cr->phone('+5509214019');
    $client_cr->save;

    # need to refresh the object after phone update
    $pnv = BOM::User::PhoneNumberVerification->new($customer->get_user_id(), $customer->get_user_service_context());
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

subtest 'Phone number taken' => sub {
    $verified = 0;
    $taken    = 1;
    generate_email_code();
    $next_attempt          = 0;
    $clear_attempts        = undef;
    $increase_attempts     = undef;
    $clear_verify_attempts = undef;

    $c->call_ok('phone_number_challenge', $params)
        ->has_no_system_error->has_error->error_code_is('PhoneNumberTaken', 'the account is already verified');

    is $increase_attempts,     undef, 'attempts increased';
    is $clear_attempts,        undef, 'attempts not cleared';
    is $clear_verify_attempts, undef, 'verify attempts not cleared';
    $taken = undef;
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
    my $client_cr = $customer->get_client_object('CR');
    my $uid       = $customer->get_user_id();

    $generate_otp_result = 1;
    $generate_otp_params = {
        carrier => undef,
        phone   => undef,
        lang    => undef,
    };

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

    is BOM::RPC::v3::Utility::is_verification_token_valid($params->{args}->{email_code}, $client_cr->email, 'phone_number_verification', 1)->{status},
        1,
        'Token was not Deleted';

    is $generate_otp, 1, 'generate otp called';

    my $phone = $pnv->phone;

    cmp_deeply $generate_otp_params,
        +{
        carrier => 'whatsapp',
        phone   => $client_cr->phone,
        lang    => 'en',
        },
        'generate OTP called with expected params';

    cmp_deeply $log->msgs(),
        [{
            category => 'BOM::RPC::v3::PhoneNumberVerification',
            level    => 'debug',
            message  => "Sending OTP to $phone, via whatsapp, for user $uid",
        }
        ],
        'expected log generated';

    is $increase_attempts,     1,     'attempts increased';
    is $clear_attempts,        undef, 'attempts not cleared';
    is $clear_verify_attempts, 1,     'verify attempts cleared';

    subtest 'try to generate an OTP again' => sub {
        $generate_otp_result = 1;
        $generate_otp_params = {
            carrier => undef,
            phone   => undef,
            lang    => undef,
        };
        $verified = 0;
        generate_email_code();

        BOM::Service::user(
            context    => $customer->get_user_service_context(),
            command    => 'update_attributes',
            user_id    => $customer->get_user_id(),
            attributes => {preferred_language => 'fr'},
        );

        $log->clear();

        $generate_otp = undef;

        $next_attempt = time;

        $increase_attempts = undef;

        $clear_attempts = undef;

        $clear_verify_attempts = undef;

        $params->{args}->{carrier} = 'sms';

        my $res = $c->call_ok('phone_number_challenge', $params)->has_no_system_error->has_no_error->result;

        is $res, 1, 'Expected result';

        is $generate_otp, 1, 'generate otp called';

        cmp_deeply $generate_otp_params,
            +{
            carrier => 'sms',
            phone   => $client_cr->phone,
            lang    => 'fr',
            },
            'generate OTP called with expected params';

        is BOM::RPC::v3::Utility::is_verification_token_valid($params->{args}->{email_code}, $client_cr->email, 'phone_number_verification', 1)
            ->{status}, 1,
            'Token was not Deleted';

        cmp_deeply $log->msgs(),
            [{
                category => 'BOM::RPC::v3::PhoneNumberVerification',
                level    => 'debug',
                message  => "Sending OTP to $phone, via sms, for user $uid",
            }
            ],
            'expected log generated';

        is $increase_attempts,     1,     'attempts increased';
        is $clear_attempts,        undef, 'attempts not cleared';
        is $clear_verify_attempts, 1,     'verify attempts cleared';
    };

};

subtest 'No carrier is given' => sub {
    my $uid = $customer->get_user_id();

    $params = {
        token    => $customer->get_client_token('CR'),
        language => 'EN',
        args     => {
            email_code => $email_code,
        }};

    subtest 'Invalid Email Code' => sub {
        $verified                     = 0;
        $next_attempt                 = 0;
        $increase_attempts            = undef;
        $params->{args}->{email_code} = "different_code";
        $c->call_ok('phone_number_challenge', $params)->has_no_system_error->has_error->error_code_is('InvalidToken', 'invalid token!');

        is $increase_attempts, 1, 'attempts increased';
    };

    subtest 'Already verified' => sub {
        $verified = 0;

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

    subtest 'Phone number taken' => sub {
        $verified = 0;
        $taken    = 1;

        $next_attempt          = 0;
        $clear_attempts        = undef;
        $increase_attempts     = undef;
        $clear_verify_attempts = undef;

        $c->call_ok('phone_number_challenge', $params)
            ->has_no_system_error->has_error->error_code_is('PhoneNumberTaken', 'the account is already verified');

        is $increase_attempts,     undef, 'attempts increased';
        is $clear_attempts,        undef, 'attempts not cleared';
        is $clear_verify_attempts, undef, 'verify attempts not cleared';
        $taken = undef;
    };

    subtest 'No attempts left' => sub {
        $verified = 0;
        generate_email_code();

        $generate_otp = undef;

        $next_attempt      = time + 1000000;
        $increase_attempts = undef;

        $clear_attempts        = undef;
        $clear_verify_attempts = undef;

        $c->call_ok('phone_number_challenge', $params)->has_no_system_error->has_error->error_code_is('NoAttemptsLeft', 'No attempts left');

        is $increase_attempts,     1,     'attempts increased';
        is $clear_attempts,        undef, 'attempts not cleared';
        is $clear_verify_attempts, undef, 'verify attempts not cleared';
    };

    subtest 'Generate a valid OTP' => sub {
        my $client_cr = $customer->get_client_object('CR');

        generate_email_code();

        $log->clear();

        $generate_otp = undef;

        $next_attempt = time;

        $increase_attempts = undef;

        $clear_attempts = undef;

        $clear_verify_attempts = undef;

        my $res = $c->call_ok('phone_number_challenge', $params)->has_no_system_error->has_no_error->result;

        is $res, 1, 'Expected result';

        is BOM::RPC::v3::Utility::is_verification_token_valid($params->{args}->{email_code}, $client_cr->email, 'phone_number_verification', 1)
            ->{status}, 1,
            'Token was not Deleted';

        is $generate_otp, undef, 'generate otp was not called with no carrier';

        my $phone = $client_cr->phone;

        cmp_deeply $log->msgs(),
            [{
                category => 'BOM::RPC::v3::PhoneNumberVerification',
                level    => 'debug',
                message  => "Successfully verified email code for user $uid for $phone",
            }
            ],
            'expected log generated';

        is $increase_attempts,     1,     'attempts increased';
        is $clear_attempts,        1,     'attempts cleared';
        is $clear_verify_attempts, undef, 'verify attempts not cleared';

        subtest 'generate a valid OTP twice, first without carrier, second with carrier ' => sub {
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

            is BOM::RPC::v3::Utility::is_verification_token_valid($params->{args}->{email_code}, $client_cr->email, 'phone_number_verification', 1)
                ->{status}, 1,
                'Token was not Deleted';

            is $generate_otp, undef, 'generate otp was not called with no carrier';

            cmp_deeply $log->msgs(),
                [{
                    category => 'BOM::RPC::v3::PhoneNumberVerification',
                    level    => 'debug',
                    message  => "Successfully verified email code for user $uid for $phone",
                }
                ],
                'expected log generated';

            is $increase_attempts,     1,     'attempts increased';
            is $clear_attempts,        1,     'attempts cleared';
            is $clear_verify_attempts, undef, 'verify attempts not cleared';

            $params = {
                token    => $customer->get_client_token('CR'),
                language => 'EN',
                args     => {
                    carrier    => 'whastapp',
                    email_code => $email_code,
                }};

            $log->clear();

            $res = $c->call_ok('phone_number_challenge', $params)->has_no_system_error->has_no_error->result;

            is $res, 1, 'Expected result';

            is BOM::RPC::v3::Utility::is_verification_token_valid($params->{args}->{email_code}, $client_cr->email, 'phone_number_verification', 1)
                ->{status}, 1,
                'Token was not Deleted';

            is $generate_otp, 1, 'generate otp called';

            cmp_deeply $log->msgs(),
                [{
                    category => 'BOM::RPC::v3::PhoneNumberVerification',
                    level    => 'debug',
                    message  => "Sending OTP to $phone, via whastapp, for user $uid",
                }
                ],
                'expected log generated';

            is $increase_attempts,     1, 'attempts increased';
            is $clear_attempts,        1, 'attempts cleared';
            is $clear_verify_attempts, 1, 'verify attempts cleared';

        };
    };

    subtest 'generate OTP failed' => sub {
        my $client_cr = $customer->get_client_object('CR');
        $generate_otp_result = 0;
        $generate_otp_params = {
            carrier => undef,
            phone   => undef,
            lang    => undef,
        };
        $verified = 0;
        generate_email_code();

        BOM::Service::user(
            context    => $customer->get_user_service_context(),
            command    => 'update_attributes',
            user_id    => $customer->get_user_id(),
            attributes => {preferred_language => 'es'},
        );

        $log->clear();

        $generate_otp = undef;

        $next_attempt = time;

        $increase_attempts = undef;

        $clear_attempts = undef;

        $clear_verify_attempts = undef;

        $params->{args}->{carrier} = 'whatsapp';

        $c->call_ok('phone_number_challenge', $params)->has_no_system_error->has_error->error_code_is('FailedToGenerateOTP', 'No attempts left');

        is $generate_otp, 1, 'generate otp called';

        my $phone = $client_cr->phone;

        cmp_deeply $generate_otp_params,
            +{
            carrier => 'whatsapp',
            phone   => $client_cr->phone,
            lang    => 'es',
            },
            'generate OTP called with expected params';

        cmp_deeply $log->msgs(),
            [{
                category => 'BOM::RPC::v3::PhoneNumberVerification',
                level    => 'debug',
                message  => "Failed to send OTP to $phone, via whatsapp, for user $uid",
            }
            ],
            'expected log generated';

        is $increase_attempts,     1,     'attempts increased';
        is $clear_attempts,        undef, 'attempts not cleared';
        is $clear_verify_attempts, undef, 'verify attempts not cleared';
    };
};

$pnv_mock->unmock_all();

sub generate_email_code {
    my $redis = BOM::Config::Redis::redis_events_write();

    $redis->del(+BOM::User::PhoneNumberVerification::PNV_NEXT_EMAIL_PREFIX . $customer->get_user_id());

    # create the token
    my @emitted;
    no warnings 'redefine';
    local *BOM::Platform::Event::Emitter::emit = sub { push @emitted, @_ };

    my $verify_email_params = {
        token    => $customer->get_client_token('CR'),
        language => 'EN',
        args     => {
            verify_email => $customer->get_email(),
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
