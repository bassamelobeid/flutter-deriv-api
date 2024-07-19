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
use BOM::Platform::Token::API;
use BOM::Test::RPC::QueueClient;
use BOM::Test::Customer;
use BOM::User;
use BOM::User::PhoneNumberVerification;
use BOM::Config::Runtime;
use BOM::Config::Redis;

my $c = BOM::Test::RPC::QueueClient->new();

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
    ]);

my $pnv = BOM::User::PhoneNumberVerification->new($customer->get_user_id(), $customer->get_user_service_context());

my $verify_blocked;
my $verify_otp;
my $verified;
my $increase_verify_attempts;
my $clear_verify_attempts;
my $valid_otp;
my $taken;
my $verified_phone;
my $verify_result = 1;

my $client_cr = $customer->get_client_object('CR');
my $phone     = $client_cr->phone;

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
    'verify',
    sub {
        my (undef, $phone) = @_;

        $verified_phone = $phone;

        return $verify_result;
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

$pnv_mock->mock(
    'is_phone_taken',
    sub {
        return $taken;
    });

my $params = {
    token    => $customer->get_client_token('CR'),
    language => 'EN',
    args     => {
        otp => undef,
    }};

subtest 'Suspended' => sub {
    BOM::Config::Runtime->instance->app_config->system->suspend->phone_number_verification(1);

    @dog_stash = ();

    my $params_vr = {
        token    => $customer->get_client_token('VR'),
        language => 'EN',
        args     => {
            otp => undef,
        }};

    $increase_verify_attempts = undef;
    $c->call_ok('phone_number_verify', $params_vr)
        ->has_no_system_error->has_error->error_code_is('PhoneNumberVerificationSuspended', 'invalid token!');

    is $increase_verify_attempts, undef, 'attempts not increased';

    cmp_deeply [@dog_stash],
        [{
            'pnv.verify.request' => {tags => ['broker:VRTC', 'residence:id',]},
        },
        {
            'pnv.verify.suspended' => {tags => ['broker:VRTC', 'residence:id',]},
        },
        ],
        'Expected dog stash';

    BOM::Config::Runtime->instance->app_config->system->suspend->phone_number_verification(0);
};

subtest 'Virtual verify' => sub {
    @dog_stash = ();

    my $params_vr = {
        token    => $customer->get_client_token('VR'),
        language => 'EN',
        args     => {
            otp => undef,
        }};

    $increase_verify_attempts = undef;
    $c->call_ok('phone_number_verify', $params_vr)->has_no_system_error->has_error->error_code_is('VirtualNotAllowed', 'invalid token!');

    is $increase_verify_attempts, undef, 'attempts not increased';

    cmp_deeply [@dog_stash],
        [{
            'pnv.verify.request' => {tags => ['broker:VRTC', 'residence:id',]},
        },
        {
            'pnv.verify.virtual_not_allowed' => {tags => ['broker:VRTC', 'residence:id',]},
        },
        ],
        'Expected dog stash';
};

subtest 'Invalid phone' => sub {
    @dog_stash = ();

    $client_cr->phone('+++');
    $client_cr->save;

    $verified_phone           = undef;
    $verified                 = undef;
    $verify_blocked           = undef;
    $clear_verify_attempts    = undef;
    $increase_verify_attempts = undef;

    $c->call_ok('phone_number_verify', $params)->has_no_system_error->has_error->error_code_is('InvalidPhone', 'invalid phone');

    is $increase_verify_attempts, undef, 'attempts not increased';
    is $clear_verify_attempts,    undef, 'attempts not cleared';
    is $verified_phone,           undef, 'phone not verified';

    $client_cr->phone($phone);
    $client_cr->save;

    cmp_deeply [@dog_stash],
        [{
            'pnv.verify.request' => {tags => ['broker:CR', 'residence:id',]},
        },
        {
            'pnv.verify.invalid_phone' => {tags => ['broker:CR', 'residence:id',]},
        },
        ],
        'Expected dog stash';
};

subtest 'Already verified' => sub {
    @dog_stash = ();

    $verified_phone           = undef;
    $verified                 = 1;
    $verify_blocked           = undef;
    $clear_verify_attempts    = undef;
    $increase_verify_attempts = undef;

    $c->call_ok('phone_number_verify', $params)->has_no_system_error->has_error->error_code_is('AlreadyVerified', 'the account is already verified');

    is $increase_verify_attempts, undef, 'attempts not increased';
    is $clear_verify_attempts,    undef, 'attempts not cleared';
    is $verified_phone,           undef, 'phone not verified';

    cmp_deeply [@dog_stash],
        [{
            'pnv.verify.request' => {tags => ['broker:CR', 'residence:id',]},
        },
        {
            'pnv.verify.already_verified' => {tags => ['broker:CR', 'residence:id',]},
        },
        ],
        'Expected dog stash';
};

subtest 'Phone number taken' => sub {
    @dog_stash = ();

    $verified_phone           = undef;
    $verified                 = 0;
    $taken                    = 1;
    $increase_verify_attempts = undef;
    $clear_verify_attempts    = undef;

    $c->call_ok('phone_number_verify', $params)->has_no_system_error->has_error->error_code_is('PhoneNumberTaken', 'the account is already verified');

    is $increase_verify_attempts, undef, 'attempts increased';
    is $clear_verify_attempts,    undef, 'verify attempts not cleared';
    is $verified_phone,           undef, 'phone not verified';
    $taken = undef;

    cmp_deeply [@dog_stash],
        [{
            'pnv.verify.request' => {tags => ['broker:CR', 'residence:id',]},
        },
        {
            'pnv.verify.phone_number_taken' => {tags => ['broker:CR', 'residence:id',]},
        },
        ],
        'Expected dog stash';
};

subtest 'No attempts left' => sub {
    @dog_stash = ();

    $verified_phone           = undef;
    $verified                 = 0;
    $verify_blocked           = 1;
    $increase_verify_attempts = undef;
    $clear_verify_attempts    = undef;

    $c->call_ok('phone_number_verify', $params)->has_no_system_error->has_error->error_code_is('NoAttemptsLeft', 'No attempts left');

    is $increase_verify_attempts, 1,     'attempts increased';
    is $clear_verify_attempts,    undef, 'attempts not cleared';
    is $verified_phone,           undef, 'phone not verified';

    cmp_deeply [@dog_stash],
        [{
            'pnv.verify.request' => {tags => ['broker:CR', 'residence:id',]},
        },
        {
            'pnv.verify.no_attempts_left' => {tags => ['broker:CR', 'residence:id',]},
        },
        ],
        'Expected dog stash';
};

subtest 'Invalid OTP' => sub {
    @dog_stash = ();

    my $uid = $customer->get_user_id;

    $verified_phone = undef;

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
            message  => "Verifying OTP $otp to $phone, for user $uid",
        }
        ],
        'expected log generated';

    is $increase_verify_attempts, 1,     'attempts increased';
    is $clear_verify_attempts,    undef, 'attempts not cleared';
    is $verified_phone,           undef, 'phone not verified';

    cmp_deeply [@dog_stash],
        [{
            'pnv.verify.request' => {tags => ['broker:CR', 'residence:id',]},
        },
        {
            'pnv.verify.invalid_otp' => {tags => ['broker:CR', 'residence:id',]},
        },
        ],
        'Expected dog stash';
};

subtest 'Valid OTP' => sub {
    @dog_stash = ();

    my $uid = $customer->get_user_id();

    $verified_phone = undef;

    my $otp = '123456';

    $params->{args}->{otp} = $otp;

    $log->clear();

    $verified = undef;

    $valid_otp = 1;

    $verify_otp = undef;

    $verify_blocked = undef;

    $increase_verify_attempts = undef;

    $clear_verify_attempts = undef;

    $verify_result = undef;

    $c->call_ok('phone_number_verify', $params)->has_no_system_error->has_error->error_code_is('PhoneNumberTaken', 'the account is already verified');

    $verify_result = 1;

    $log->clear();

    cmp_deeply [@dog_stash], [{
            'pnv.verify.request' => {tags => ['broker:CR', 'residence:id',]},
        },
        {
            'pnv.verify.phone_number_taken_maybe' => {tags => ['broker:CR', 'residence:id',]}
            ,    # the maybe is because a race condition is the only reason
        },
        ],
        'Expected dog stash';

    @dog_stash = ();

    my $res = $c->call_ok('phone_number_verify', $params)->has_no_system_error->has_no_error->result;

    is $res, 1, 'Expected result';

    is $verify_otp, 1, 'verify otp called';
    cmp_deeply $log->msgs(),
        [{
            category => 'BOM::RPC::v3::PhoneNumberVerification',
            level    => 'debug',
            message  => "Verifying OTP $otp to $phone, for user $uid",
        }
        ],
        'expected log generated';

    is $increase_verify_attempts, 1,                 'attempts increased';
    is $clear_verify_attempts,    1,                 'attempts cleared';
    is $verified_phone,           $client_cr->phone, 'phone is verified';

    cmp_deeply [@dog_stash],
        [{
            'pnv.verify.request' => {tags => ['broker:CR', 'residence:id',]},
        },
        {
            'pnv.verify.success' => {tags => ['broker:CR', 'residence:id',]},
        },
        ],
        'Expected dog stash';

    subtest 'try to verify an OTP again' => sub {
        @dog_stash = ();

        $verified_phone = undef;

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
        is $verified_phone,           undef, 'phone not verified';

        cmp_deeply [@dog_stash],
            [{
                'pnv.verify.request' => {tags => ['broker:CR', 'residence:id',]},
            },
            {
                'pnv.verify.already_verified' => {tags => ['broker:CR', 'residence:id',]},
            },
            ],
            'Expected dog stash';
    };
};

$pnv_mock->unmock_all();
$dd_mock->unmock_all();

done_testing();
