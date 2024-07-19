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

my $c     = BOM::Test::RPC::QueueClient->new();
my $redis = BOM::Config::Redis::redis_events();

my $dd_mock = Test::MockModule->new('BOM::RPC::v3::PhoneNumberVerification');
my @dog_stash;
$dd_mock->mock(
    'stats_inc',
    sub {
        push @dog_stash, +{@_};
    });

my $customer = BOM::Test::Customer->create(
    clients => [{
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
my $count = 0;

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

subtest 'Suspended' => sub {
    BOM::Config::Runtime->instance->app_config->system->suspend->phone_number_verification(1);

    @dog_stash = ();

    my $params_vr = {
        token    => $customer->get_client_token('VR'),
        language => 'EN',
        args     => {
            carrier    => 'whatsapp',
            email_code => $email_code,
        }};

    $increase_attempts = undef;
    $c->call_ok('phone_number_challenge', $params_vr)
        ->has_no_system_error->has_error->error_code_is('PhoneNumberVerificationSuspended', 'suspended!');

    is $increase_attempts, undef, 'attempts not increased';

    cmp_deeply [@dog_stash],
        [{
            'pnv.challenge.request' => {tags => ['broker:VRTC', 'residence:id', 'carrier:whatsapp',]},
        },
        {
            'pnv.challenge.suspended' => {tags => ['broker:VRTC', 'residence:id', 'carrier:whatsapp',]},
        },
        ],
        'Expected dog stash';

    BOM::Config::Runtime->instance->app_config->system->suspend->phone_number_verification(0);
};

subtest 'SMS is Suspended' => sub {
    BOM::Config::Runtime->instance->app_config->system->suspend->pnv_sms(1);

    @dog_stash = ();

    my $params_vr = {
        token    => $customer->get_client_token('VR'),
        language => 'EN',
        args     => {
            carrier    => 'sms',
            email_code => $email_code,
        }};

    $increase_attempts = undef;
    $c->call_ok('phone_number_challenge', $params_vr)
        ->has_no_system_error->has_error->error_code_is('PhoneNumberVerificationSuspended', 'suspended!');

    is $increase_attempts, undef, 'attempts not increased';

    cmp_deeply [@dog_stash],
        [{
            'pnv.challenge.request' => {tags => ['broker:VRTC', 'residence:id', 'carrier:sms',]},
        },
        {
            'pnv.challenge.sms_suspended' => {tags => ['broker:VRTC', 'residence:id', 'carrier:sms',]},
        },
        ],
        'Expected dog stash';

    BOM::Config::Runtime->instance->app_config->system->suspend->pnv_sms(0);
};

subtest 'SMS is Depleted' => sub {
    $redis->set(+BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . 'sms', 5000);

    @dog_stash = ();

    my $params_vr = {
        token    => $customer->get_client_token('VR'),
        language => 'EN',
        args     => {
            carrier    => 'sms',
            email_code => $email_code,
        }};

    $increase_attempts = undef;
    $c->call_ok('phone_number_challenge', $params_vr)
        ->has_no_system_error->has_error->error_code_is('PhoneNumberVerificationSuspended', 'suspended!');

    is $increase_attempts, undef, 'attempts not increased';

    cmp_deeply [@dog_stash],
        [{
            'pnv.challenge.request' => {tags => ['broker:VRTC', 'residence:id', 'carrier:sms',]},
        },
        {
            'pnv.challenge.sms_depleted' => {tags => ['broker:VRTC', 'residence:id', 'carrier:sms',]},
        },
        ],
        'Expected dog stash';

    $redis->del(+BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . 'sms');
};

subtest 'An unkwnon carrier is always Suspended' => sub {
    @dog_stash = ();

    my $params_vr = {
        token    => $customer->get_client_token('VR'),
        language => 'EN',
        args     => {
            carrier    => 'telegram',
            email_code => $email_code,
        }};

    $increase_attempts = undef;
    $c->call_ok('phone_number_challenge', $params_vr)
        ->has_no_system_error->has_error->error_code_is('PhoneNumberVerificationSuspended', 'suspended!');

    is $increase_attempts, undef, 'attempts not increased';

    cmp_deeply [@dog_stash],
        [{
            'pnv.challenge.request' => {tags => ['broker:VRTC', 'residence:id', 'carrier:telegram',]},
        },
        {
            'pnv.challenge.unsupported_carrier' => {tags => ['broker:VRTC', 'residence:id', 'carrier:telegram',]},
        },
        ],
        'Expected dog stash';
};

subtest 'Whatsapp is Suspended' => sub {
    BOM::Config::Runtime->instance->app_config->system->suspend->pnv_whatsapp(1);

    @dog_stash = ();

    my $params_vr = {
        token    => $customer->get_client_token('VR'),
        language => 'EN',
        args     => {
            carrier    => 'whatsapp',
            email_code => $email_code,
        }};

    $increase_attempts = undef;
    $c->call_ok('phone_number_challenge', $params_vr)
        ->has_no_system_error->has_error->error_code_is('PhoneNumberVerificationSuspended', 'suspended!');

    is $increase_attempts, undef, 'attempts not increased';

    cmp_deeply [@dog_stash],
        [{
            'pnv.challenge.request' => {tags => ['broker:VRTC', 'residence:id', 'carrier:whatsapp',]},
        },
        {
            'pnv.challenge.whatsapp_suspended' => {tags => ['broker:VRTC', 'residence:id', 'carrier:whatsapp',]},
        },
        ],
        'Expected dog stash';

    BOM::Config::Runtime->instance->app_config->system->suspend->pnv_whatsapp(0);
};

subtest 'Whatsapp is Depleted' => sub {
    $redis->set(+BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . 'whatsapp', 5000);

    @dog_stash = ();

    my $params_vr = {
        token    => $customer->get_client_token('VR'),
        language => 'EN',
        args     => {
            carrier    => 'whatsapp',
            email_code => $email_code,
        }};

    $increase_attempts = undef;
    $c->call_ok('phone_number_challenge', $params_vr)
        ->has_no_system_error->has_error->error_code_is('PhoneNumberVerificationSuspended', 'suspended!');

    is $increase_attempts, undef, 'attempts not increased';

    cmp_deeply [@dog_stash],
        [{
            'pnv.challenge.request' => {tags => ['broker:VRTC', 'residence:id', 'carrier:whatsapp',]},
        },
        {
            'pnv.challenge.whatsapp_depleted' => {tags => ['broker:VRTC', 'residence:id', 'carrier:whatsapp',]},
        },
        ],
        'Expected dog stash';

    $redis->del(+BOM::User::PhoneNumberVerification::PNV_GLOBAL_LIMIT . 'whatsapp');
};

subtest 'Virtual challenge' => sub {
    @dog_stash = ();

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

    cmp_deeply [@dog_stash],
        [{
            'pnv.challenge.request' => {tags => ['broker:VRTC', 'residence:id', 'carrier:whatsapp',]},
        },
        {
            'pnv.challenge.virtual_not_allowed' => {tags => ['broker:VRTC', 'residence:id', 'carrier:whatsapp',]},
        },
        ],
        'Expected dog stash';
};

subtest 'Invalid Email Code' => sub {
    @dog_stash = ();

    $verified          = 0;
    $next_attempt      = 0;
    $increase_attempts = undef;
    $c->call_ok('phone_number_challenge', $params)->has_no_system_error->has_error->error_code_is('InvalidToken', 'virtual is not allowed!');

    is $increase_attempts, 1, 'attempts increased';

    cmp_deeply [@dog_stash],
        [{
            'pnv.challenge.request' => {tags => ['broker:CR', 'residence:id', 'carrier:whatsapp',]},
        },
        {'pnv.challenge.invalid_email_code' => {tags => ['broker:CR', 'residence:id', 'carrier:whatsapp',]}}
        ],
        'Expected dog stash';
};

subtest 'Invalid Phone Number' => sub {
    @dog_stash = ();

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

    cmp_deeply [@dog_stash],
        [{
            'pnv.challenge.request' => {tags => ['broker:CR', 'residence:id', 'carrier:whatsapp',]},
        },
        {'pnv.challenge.invalid_phone' => {tags => ['broker:CR', 'residence:id', 'carrier:whatsapp',]}}
        ],
        'Expected dog stash';
};

subtest 'Already verified' => sub {
    @dog_stash = ();

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

    cmp_deeply [@dog_stash],
        [{
            'pnv.challenge.request' => {tags => ['broker:CR', 'residence:id', 'carrier:whatsapp',]},
        },
        {'pnv.challenge.already_verified' => {tags => ['broker:CR', 'residence:id', 'carrier:whatsapp',]}}
        ],
        'Expected dog stash';
};

subtest 'Phone number taken' => sub {
    @dog_stash = ();

    $verified = 0;
    $taken    = 1;
    generate_email_code();
    $next_attempt          = 0;
    $clear_attempts        = undef;
    $increase_attempts     = undef;
    $clear_verify_attempts = undef;

    $c->call_ok('phone_number_challenge', $params)
        ->has_no_system_error->has_error->error_code_is('PhoneNumberTaken', 'the phone number is not available.');

    is $increase_attempts,     undef, 'attempts increased';
    is $clear_attempts,        undef, 'attempts not cleared';
    is $clear_verify_attempts, undef, 'verify attempts not cleared';
    $taken = undef;

    cmp_deeply [@dog_stash],
        [{
            'pnv.challenge.request' => {tags => ['broker:CR', 'residence:id', 'carrier:whatsapp',]},
        },
        {'pnv.challenge.phone_number_taken' => {tags => ['broker:CR', 'residence:id', 'carrier:whatsapp',]}}
        ],
        'Expected dog stash';
};

subtest 'No attempts left' => sub {
    @dog_stash = ();

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

    cmp_deeply [@dog_stash],
        [{
            'pnv.challenge.request' => {tags => ['broker:CR', 'residence:id', 'carrier:whatsapp',]},
        },
        {'pnv.challenge.no_attempts_left' => {tags => ['broker:CR', 'residence:id', 'carrier:whatsapp',]}}
        ],
        'Expected dog stash';
};

subtest 'Generate a valid OTP' => sub {
    @dog_stash = ();

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

    cmp_deeply [@dog_stash],
        [{
            'pnv.challenge.request' => {tags => ['broker:CR', 'residence:id', 'carrier:whatsapp',]},
        },
        {'pnv.challenge.success' => {tags => ['broker:CR', 'residence:id', 'carrier:whatsapp',]}}
        ],
        'Expected dog stash';

    subtest 'try to generate an OTP again' => sub {
        @dog_stash           = ();
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

        @dog_stash = ();

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

        cmp_deeply [@dog_stash],
            [{
                'pnv.challenge.request' => {tags => ['broker:CR', 'residence:id', 'carrier:sms',]},
            },
            {'pnv.challenge.success' => {tags => ['broker:CR', 'residence:id', 'carrier:sms',]}}
            ],
            'Expected dog stash';
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
        @dog_stash = ();

        $verified                     = 0;
        $next_attempt                 = 0;
        $increase_attempts            = undef;
        $params->{args}->{email_code} = "different_code";
        $c->call_ok('phone_number_challenge', $params)->has_no_system_error->has_error->error_code_is('InvalidToken', 'invalid token!');

        is $increase_attempts, 1, 'attempts increased';
    };

    subtest 'Already verified' => sub {
        @dog_stash = ();

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

        cmp_deeply [@dog_stash],
            [{
                'pnv.challenge.request' => {tags => ['broker:CR', 'residence:id',]},
            },
            {'pnv.challenge.already_verified' => {tags => ['broker:CR', 'residence:id',]}}
            ],
            'Expected dog stash';
    };

    subtest 'Phone number taken' => sub {
        @dog_stash = ();

        $verified = 0;
        $taken    = 1;

        $next_attempt          = 0;
        $clear_attempts        = undef;
        $increase_attempts     = undef;
        $clear_verify_attempts = undef;

        $c->call_ok('phone_number_challenge', $params)
            ->has_no_system_error->has_error->error_code_is('PhoneNumberTaken', 'the phone number is not available');

        is $increase_attempts,     undef, 'attempts increased';
        is $clear_attempts,        undef, 'attempts not cleared';
        is $clear_verify_attempts, undef, 'verify attempts not cleared';
        $taken = undef;

        cmp_deeply [@dog_stash],
            [{
                'pnv.challenge.request' => {tags => ['broker:CR', 'residence:id',]},
            },
            {'pnv.challenge.phone_number_taken' => {tags => ['broker:CR', 'residence:id',]}}
            ],
            'Expected dog stash';
    };

    subtest 'No attempts left' => sub {
        @dog_stash = ();

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

        cmp_deeply [@dog_stash],
            [{
                'pnv.challenge.request' => {tags => ['broker:CR', 'residence:id',]},
            },
            {'pnv.challenge.no_attempts_left' => {tags => ['broker:CR', 'residence:id',]}}
            ],
            'Expected dog stash';
    };

    subtest 'Generate a valid OTP' => sub {
        @dog_stash = ();

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

        cmp_deeply [@dog_stash],
            [{
                'pnv.challenge.request' => {tags => ['broker:CR', 'residence:id',]},
            },
            {'pnv.challenge.verify_code_only' => {tags => ['broker:CR', 'residence:id',]}}
            ],
            'Expected dog stash';

        subtest 'generate a valid OTP twice, first without carrier, second with carrier ' => sub {
            @dog_stash = ();

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

            cmp_deeply [@dog_stash],
                [{
                    'pnv.challenge.request' => {tags => ['broker:CR', 'residence:id',]},
                },
                {'pnv.challenge.verify_code_only' => {tags => ['broker:CR', 'residence:id',]}}
                ],
                'Expected dog stash';

            $params = {
                token    => $customer->get_client_token('CR'),
                language => 'EN',
                args     => {
                    carrier    => 'whatsapp',
                    email_code => $email_code,
                }};

            $log->clear();

            @dog_stash = ();

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
                    message  => "Sending OTP to $phone, via whatsapp, for user $uid",
                }
                ],
                'expected log generated';

            is $increase_attempts,     1, 'attempts increased';
            is $clear_attempts,        1, 'attempts cleared';
            is $clear_verify_attempts, 1, 'verify attempts cleared';

            cmp_deeply [@dog_stash],
                [{
                    'pnv.challenge.request' => {tags => ['broker:CR', 'residence:id', 'carrier:whatsapp',]},
                },
                {'pnv.challenge.success' => {tags => ['broker:CR', 'residence:id', 'carrier:whatsapp',]}}
                ],
                'Expected dog stash';
        };
    };

    subtest 'generate OTP failed' => sub {
        @dog_stash = ();

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

        cmp_deeply [@dog_stash],
            [{
                'pnv.challenge.request' => {tags => ['broker:CR', 'residence:id', 'carrier:whatsapp',]},
            },
            {'pnv.challenge.failed_otp' => {tags => ['broker:CR', 'residence:id', 'carrier:whatsapp',]}}
            ],
            'Expected dog stash';
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

$dd_mock->unmock_all;

done_testing();
