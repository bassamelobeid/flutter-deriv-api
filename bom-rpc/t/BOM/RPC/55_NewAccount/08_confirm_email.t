use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Test::Deep;
use Test::MockModule;
use Test::FailWarnings;
use Test::Warn;
use Test::Fatal qw(lives_ok exception);
use BOM::Test::Customer;

use Date::Utility;
use MojoX::JSON::RPC::Client;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Email                           qw(:no_event);
use BOM::Test::RPC::QueueClient;
use Syntax::Keyword::Try;
use BOM::Platform::Token;
use BOM::User::Client;
use JSON::MaybeUTF8 qw(encode_json_utf8 decode_json_utf8);
use BOM::Platform::Token::API;
use BOM::Config::Runtime;
use BOM::Service;

$ENV{EMAIL_SENDER_TRANSPORT} = 'Test';

my ($params, $rpc_ct, $method);

$params = {
    language => 'EN',
    source   => 1,
    country  => 'id',
    args     => {},
};

my $verify_email_expected_response = {
    stash => {
        app_markup_percentage      => 0,
        valid_source               => 1,
        source_bypass_verification => 0,
        source_type                => 'official',
    },
    status => 1
};

my $verify_email_args = {
    verify_email => 'email',
    type         => 'account_verification',
};

my $confirm_email_args = {
    confirm_email     => 1,
    verification_code => 'verification_code',
    email_consent     => 1
};

subtest 'Initialization' => sub {
    lives_ok {
        $rpc_ct = BOM::Test::RPC::QueueClient->new();
    }
    'Initial RPC server and client connection';
};

$method = 'confirm_email';

subtest $method => sub {

    subtest 'verification_code token validation' => sub {
        my $customer = BOM::Test::Customer->create({
                email    => BOM::Test::Customer->get_random_email_address(),
                password => BOM::User::Password::hashpw('jskjd8292922'),
            },
            [{
                    name        => 'CR',
                    broker_code => 'CR',
                },
            ]);

        #wrong token
        $params->{args}->{verification_code} = 'wrong_token';
        $params->{args}->{email_consent}     = 1;

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InvalidToken', 'If email verification_code is wrong it should return error')
            ->error_message_is('Your token has expired or is invalid.', 'If email verification_code is wrong it should return error_message');

        #incorrect token type
        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $customer->get_email(),
            created_for => 'account_opening',
        )->token;

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InvalidToken', 'If email verification_code type is wrong it should return error')
            ->error_message_is('Your token has expired or is invalid.', 'If email verification_code type is wrong it should return error_message');

        #expired token
        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $customer->get_email(),
            created_for => 'account_verification',
            expires_in  => -1,
        )->token;

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InvalidToken', 'If email verification_code is expired it should return error')
            ->error_message_is('Your token has expired or is invalid.', 'If email verification_code is expired it should return error_message');

        #correct token
        my $user_data = BOM::Service::user(
            context    => $customer->get_user_service_context(),
            command    => 'get_attributes',
            user_id    => $customer->get_email(),
            attributes => [qw(email_consent email_verified)],
        );
        is($user_data->{status}, 'ok', 'user service call succeeded');
        ok(!$user_data->{attributes}{email_verified}, 'User should not be email verified');
        ok(!$user_data->{attributes}{email_consent},  'User should not be email consented');

        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $customer->get_email(),
            created_for => 'account_verification',
        )->token;

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('If verification code is ok - account verified successfully');

        $user_data = BOM::Service::user(
            context    => $customer->get_user_service_context(),
            command    => 'get_attributes',
            user_id    => $customer->get_email(),
            attributes => [qw(email_consent email_verified)],
        );
        is($user_data->{status}, 'ok', 'user service call succeeded');
        #user should be email verified
        ok($user_data->{attributes}{email_verified}, 'User should be email verified after verification');

        #email consent should be updated
        ok($user_data->{attributes}{email_consent}, 'User email consent should be updated');

    };

    subtest 'already verified user' => sub {
        my $customer = BOM::Test::Customer->create({
                email          => BOM::Test::Customer->get_random_email_address(),
                password       => BOM::User::Password::hashpw('jskjd8292922'),
                email_verified => 1,
            },
            [{
                    name        => 'CR',
                    broker_code => 'CR',
                },
            ]);

        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $customer->get_email(),
            created_for => 'account_verification',
        )->token;

        my $user_data = BOM::Service::user(
            context    => $customer->get_user_service_context(),
            command    => 'get_attributes',
            user_id    => $customer->get_email(),
            attributes => [qw(email_consent email_verified)],
        );
        is($user_data->{status},                     'ok', 'user service response ok');
        is($user_data->{attributes}{email_verified}, 1,    'email is verified');

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('UserAlreadyVerified', 'If user already email verified it should return error')
            ->error_message_is('User is already email verified.', 'If user already email verified it should return error_message');

    };

    subtest 'invalid user' => sub {
        my $email = BOM::Test::Customer->get_random_email_address();

        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $email,
            created_for => 'account_verification',
        )->token;

        my $user_data = BOM::Service::user(
            context    => BOM::Test::Customer::get_user_service_context(),
            command    => 'get_attributes',
            user_id    => $email,
            attributes => [qw(email_consent email_verified)],
        );
        is $user_data->{status}, 'error',        'user not found';
        is $user_data->{class},  'UserNotFound', 'user not found class';

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('InvalidUser', 'If user not found it should return error')
            ->error_message_is('No user found.', 'If user not found it should return error_message');
    };

    subtest 'email_consent' => sub {
        my $customer = BOM::Test::Customer->create({
                email    => BOM::Test::Customer->get_random_email_address(),
                password => BOM::User::Password::hashpw('jskjd8292922'),
            },
            [{
                    name        => 'CR',
                    broker_code => 'CR',
                },
            ]);

        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $customer->get_email(),
            created_for => 'account_verification',
        )->token;

        $params->{args}->{email_consent} = 1;

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('If verification code is ok - account verified successfully');

        my $user_data = BOM::Service::user(
            context    => $customer->get_user_service_context(),
            command    => 'get_attributes',
            user_id    => $customer->get_email(),
            attributes => [qw(email_consent email_verified)],
        );
        is($user_data->{status}, 'ok', 'user service call succeeded');
        ok($user_data->{attributes}{email_verified}, 'User should be email verified');
        ok($user_data->{attributes}{email_consent},  'User should be email consented');

        #email consent should not be updated when verification code check fails
        $user_data = BOM::Service::user(
            context    => $customer->get_user_service_context(),
            command    => 'update_attributes',
            user_id    => $customer->get_email(),
            attributes => {email_consent => 0},
        );
        is $user_data->{status}, 'ok', 'user service call succeeded';

        $params->{args}->{verification_code} = 'wrong_token';

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InvalidToken', 'If email verification_code is wrong it should return error')
            ->error_message_is('Your token has expired or is invalid.', 'If email verification_code is wrong it should return error_message');

        $user_data = BOM::Service::user(
            context    => $customer->get_user_service_context(),
            command    => 'get_attributes',
            user_id    => $customer->get_email(),
            attributes => [qw(email_consent)],
        );
        is $user_data->{status}, 'ok', 'user service call succeeded';
        ok(!$user_data->{attributes}{email_consent}, 'User email consent should not be updated when token validation fails');

        #email consent should not be updated if email if already verified
        $user_data = BOM::Service::user(
            context    => $customer->get_user_service_context(),
            command    => 'update_attributes',
            user_id    => $customer->get_email(),
            attributes => {
                email_consent  => 0,
                email_verified => 1
            },
        );
        is $user_data->{status}, 'ok', 'user service call succeeded';

        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $customer->get_email(),
            created_for => 'account_verification',
        )->token;

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('UserAlreadyVerified', 'If user already email verified it should return error')
            ->error_message_is('User is already email verified.', 'If user already email verified it should return error_message');

        $user_data = BOM::Service::user(
            context    => $customer->get_user_service_context(),
            command    => 'get_attributes',
            user_id    => $customer->get_email(),
            attributes => [qw(email_consent)],
        );
        is($user_data->{status}, 'ok', 'user service call succeeded');
        ok(!$user_data->{attributes}{email_consent}, 'User email consent should not be updated when token validation fails');
    };

    subtest 'confirm_email full flow' => sub {
        my @emitted_event;
        no warnings 'redefine';
        local *BOM::Platform::Event::Emitter::emit = sub { push @emitted_event, @_ };

        for my $feature_flag (1, 0) {
            #Testing against feature flag
            BOM::Config::Runtime->instance->app_config->email_verification->suspend->virtual_accounts($feature_flag);

            my $email = BOM::Test::Customer->get_random_email_address();

            subtest 'non-existing user' => sub {
                $verify_email_args->{verify_email} = $email;
                $params->{args}                    = $verify_email_args;

                $rpc_ct->call_ok('verify_email', $params)->has_no_system_error->has_no_error->result_is_deeply($verify_email_expected_response,
                    "It always should return 1, so not to leak client's email");
                is(scalar @emitted_event, 0, 'no email as user does not exist');
                @emitted_event = ();

                my $verification_code = BOM::Platform::Token->new(
                    email       => $email,
                    created_for => 'account_verification',
                )->token;

                $confirm_email_args->{verification_code} = $verification_code;
                $params->{args}                          = $confirm_email_args;

                $rpc_ct->call_ok($method, $params)
                    ->has_no_system_error->has_error->error_code_is('InvalidUser', 'If user not found it should return error')
                    ->error_message_is('No user found.', 'If user not found it should return error_message');
            };

            subtest 'existing user without email verified' => sub {
                my $customer = BOM::Test::Customer->create({
                        email          => BOM::Test::Customer->get_random_email_address(),
                        password       => BOM::User::Password::hashpw('jskjd8292922'),
                        residence      => 'au',
                        account_type   => 'binary',
                        email_verified => 0,
                        email_consent  => 0,
                    },
                    [{
                            name        => 'VRTC',
                            broker_code => 'VRTC',
                        },
                    ]);

                my $user_data = BOM::Service::user(
                    context    => $customer->get_user_service_context(),
                    command    => 'get_attributes',
                    user_id    => $customer->get_email(),
                    attributes => [qw(email_consent)],
                );
                is($user_data->{status}, 'ok', 'user service call succeeded');
                ok(!$user_data->{attributes}{email_verified}, 'User is not email verified');

                $verify_email_args->{verify_email} = $customer->get_email();
                $params->{args}                    = $verify_email_args;

                $rpc_ct->call_ok('verify_email', $params)->has_no_system_error->has_no_error->result_is_deeply($verify_email_expected_response,
                    "It always should return 1, so not to leak client's email");
                is($emitted_event[1]->{email}, $customer->get_email(), 'email is sent to user');
                is($emitted_event[0],          'account_verification', 'email type is account_verification');

                $confirm_email_args->{verification_code} = $emitted_event[1]->{code};
                $params->{args}                          = $confirm_email_args;

                $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('If verification code is ok - account verified successfully');

                $user_data = BOM::Service::user(
                    context    => $customer->get_user_service_context(),
                    command    => 'get_attributes',
                    user_id    => $customer->get_email(),
                    attributes => [qw(email_consent email_verified)],
                );
                is($user_data->{status}, 'ok', 'user service call succeeded');
                ok($user_data->{attributes}{email_verified}, 'User should be email verified');
                ok($user_data->{attributes}{email_consent},  'User should be email consented');

                @emitted_event = ();
            };

            subtest 'exisiting user already email verified' => sub {
                my $customer = BOM::Test::Customer->create({
                        email          => BOM::Test::Customer->get_random_email_address(),
                        password       => BOM::User::Password::hashpw('jskjd8292922'),
                        residence      => 'au',
                        account_type   => 'binary',
                        email_verified => 1,
                        email_consent  => 0,
                    },
                    [{
                            name        => 'VRTC',
                            broker_code => 'VRTC',
                        },
                    ]);

                my $user_data = BOM::Service::user(
                    context    => $customer->get_user_service_context(),
                    command    => 'get_attributes',
                    user_id    => $customer->get_email(),
                    attributes => [qw(email_verified)],
                );
                is($user_data->{status}, 'ok', 'user service call succeeded');
                ok($user_data->{attributes}{email_verified}, 'User should be email verified');

                $verify_email_args->{verify_email} = $customer->get_email();
                $params->{args}                    = $verify_email_args;

                $rpc_ct->call_ok('verify_email', $params)->has_no_system_error->has_no_error->result_is_deeply($verify_email_expected_response,
                    "It always should return 1, so not to leak client's email");
                isnt($emitted_event[1]->{email}, $customer->get_email(), 'email is not sent to user');

                @emitted_event = ();
            };

            subtest 'Incorrect code type from verify_email' => sub {
                my $customer = BOM::Test::Customer->create({
                        email        => BOM::Test::Customer->get_random_email_address(),
                        password     => BOM::User::Password::hashpw('jskjd8292922'),
                        residence    => 'au',
                        account_type => 'binary',
                    },
                    [{
                            name        => 'VRTC',
                            broker_code => 'VRTC',
                        },
                    ]);

                my $user_data = BOM::Service::user(
                    context    => $customer->get_user_service_context(),
                    command    => 'get_attributes',
                    user_id    => $customer->get_email(),
                    attributes => [qw(email_verified)],
                );
                is($user_data->{status}, 'ok', 'user service call succeeded');
                ok(!$user_data->{attributes}{email_verified}, 'User should not be email verified');

                $verify_email_args->{verify_email} = $customer->get_email();
                $verify_email_args->{type}         = 'account_opening';
                $params->{args}                    = $verify_email_args;

                $rpc_ct->call_ok('verify_email', $params)->has_no_system_error->has_no_error->result_is_deeply($verify_email_expected_response,
                    "It always should return 1, so not to leak client's email");

                is($emitted_event[1]->{properties}->{email}, $customer->get_email(), 'email is sent to user');
                isnt($emitted_event[0], 'account_verification', 'email type is not account_verification');

                $confirm_email_args->{verification_code} = $emitted_event[1]->{properties}->{code};
                $params->{args}                          = $confirm_email_args;

                $rpc_ct->call_ok($method, $params)
                    ->has_no_system_error->has_error->error_code_is('InvalidToken', 'If email verification_code type is wrong it should return error')
                    ->error_message_is('Your token has expired or is invalid.',
                    'If email verification_code type is wrong it should return error_message');

                $user_data = BOM::Service::user(
                    context    => $customer->get_user_service_context(),
                    command    => 'get_attributes',
                    user_id    => $customer->get_email(),
                    attributes => [qw(email_consent email_verified)],
                );
                is($user_data->{status}, 'ok', 'user service call succeeded');
                ok(!$user_data->{attributes}{email_verified}, 'User should not be email verified when token invalid');
                ok(!$user_data->{attributes}{email_consent},  'User email consent should not be updated when email is already verified');

                @emitted_event = ();
            };

            subtest 'Expired code from verify_email' => sub {
                my $customer = BOM::Test::Customer->create({
                        email        => BOM::Test::Customer->get_random_email_address(),
                        password     => BOM::User::Password::hashpw('jskjd8292922'),
                        residence    => 'au',
                        account_type => 'binary',
                    },
                    [{
                            name        => 'VRTC',
                            broker_code => 'VRTC',
                        },
                    ]);

                my $user_data = BOM::Service::user(
                    context    => $customer->get_user_service_context(),
                    command    => 'get_attributes',
                    user_id    => $customer->get_email(),
                    attributes => [qw(email_verified)],
                );
                is($user_data->{status}, 'ok', 'user service call succeeded');
                ok(!$user_data->{attributes}{email_verified}, 'User should not be email verified');

                my $mock = Test::MockModule->new('BOM::RPC::v3::VerifyEmail::Functions');
                $mock->mock(
                    'create_token' => sub {
                        my ($self) = @_;
                        $self->{code} = BOM::Platform::Token->new({
                                email       => $self->{email},
                                expires_in  => -1,
                                created_for => $self->{type},
                            })->token;
                        return;
                    },
                );

                $verify_email_args->{verify_email} = $customer->get_email();
                $verify_email_args->{type}         = 'account_verification';
                $params->{args}                    = $verify_email_args;

                $rpc_ct->call_ok('verify_email', $params)->has_no_system_error->has_no_error->result_is_deeply($verify_email_expected_response,
                    "It always should return 1, so not to leak client's email");
                use Data::Dump qw(pp);

                is($emitted_event[1]->{email}, $customer->get_email(), 'email is sent to user');
                is($emitted_event[0],          'account_verification', 'email type is account_verification');

                $confirm_email_args->{verification_code} = $emitted_event[1]->{code};
                $params->{args}                          = $confirm_email_args;

                $rpc_ct->call_ok('confirm_email', $params)
                    ->has_no_system_error->has_error->error_code_is('InvalidToken', 'If email verification_code is expired it should return error')
                    ->error_message_is('Your token has expired or is invalid.',
                    'If email verification_code is expired it should return error_message');

                $user_data = BOM::Service::user(
                    context    => $customer->get_user_service_context(),
                    command    => 'get_attributes',
                    user_id    => $customer->get_email(),
                    attributes => [qw(email_consent email_verified)],
                );
                is($user_data->{status}, 'ok', 'user service call succeeded');
                ok(!$user_data->{attributes}{email_verified}, 'User should not be email verified when token invalid');
                ok(!$user_data->{attributes}{email_consent},  'User email consent should not be updated when email is already verified');

                @emitted_event = ();
                $mock->unmock('create_token');
            };

        }
    }
};

done_testing();
