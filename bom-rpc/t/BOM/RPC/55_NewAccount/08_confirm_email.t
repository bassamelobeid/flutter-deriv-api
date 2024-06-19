use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Test::Deep;
use Test::MockModule;
use Test::FailWarnings;
use Test::Warn;
use Test::Fatal qw(lives_ok exception);

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

my $acc_args = {
    details => {
        email           => 'email',
        client_password => 'secret_pwd',
        residence       => 'au',
        account_type    => 'binary',
        email_verified  => 0,
        email_consent   => 0,
    },
};

subtest 'Initialization' => sub {
    lives_ok {
        $rpc_ct = BOM::Test::RPC::QueueClient->new();
    }
    'Initial RPC server and client connection';
};

my $password = 'jskjd8292922';
my $hash_pwd = BOM::User::Password::hashpw($password);

$method = 'confirm_email';
my $email = sprintf('Test%.5f@deriv.com', rand(999));

sub create_user {
    my ($email, $email_verified, $email_consent) = @_;

    my $user = BOM::User->create(
        email          => $email,
        password       => $hash_pwd,
        email_verified => $email_verified // 0,
        email_consent  => $email_consent  // 0,
    );

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        binary_user_id => $user->id,
    });
    $user->add_client($client);

    return $user;
}

subtest $method => sub {

    my $password = 'jskjd8292922';
    my $hash_pwd = BOM::User::Password::hashpw($password);

    my $user = create_user($email);

    subtest 'verification_code token validation' => sub {
        #wrong token
        $params->{args}->{verification_code} = 'wrong_token';
        $params->{args}->{email_consent}     = 1;

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InvalidToken', 'If email verification_code is wrong it should return error')
            ->error_message_is('Your token has expired or is invalid.', 'If email verification_code is wrong it should return error_message');

        #incorrect token type
        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $email,
            created_for => 'account_opening',
        )->token;

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InvalidToken', 'If email verification_code type is wrong it should return error')
            ->error_message_is('Your token has expired or is invalid.', 'If email verification_code type is wrong it should return error_message');

        #expired token
        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $email,
            created_for => 'account_verification',
            expires_in  => -1,
        )->token;

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InvalidToken', 'If email verification_code is expired it should return error')
            ->error_message_is('Your token has expired or is invalid.', 'If email verification_code is expired it should return error_message');

        #correct token
        my $user = BOM::User->new(email => $email);

        ok(!$user->email_verified, 'User should not be email verified');
        ok(!$user->email_consent,  'User should not be email consented');

        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $email,
            created_for => 'account_verification',
        )->token;

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('If verification code is ok - account verified successfully');

        $user = BOM::User->new(email => $email);
        #user should be email verified
        ok($user->email_verified, 'User should be email verified after verification');

        #email consent should be updated
        ok($user->email_consent, 'User email consent should be updated');

        #Already verified user
        $email = sprintf('Test%.5f@deriv.com', rand(999));
        $user  = create_user($email, 1, 0);

        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $email,
            created_for => 'account_verification',
        )->token;

        ok($user->email_verified, 'User should be already email verified');

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('UserAlreadyVerified', 'If user already email verified it should return error')
            ->error_message_is('User is already email verified.', 'If user already email verified it should return error_message');

        #Invalid user
        $email = sprintf('Test%.5f@deriv.com', rand(999));

        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $email,
            created_for => 'account_verification',
        )->token;

        $user = BOM::User->new(email => $email);
        is($user, undef, 'User not found');

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('InvalidUser', 'If user not found it should return error')
            ->error_message_is('No user found.', 'If user not found it should return error_message');

    };

    subtest 'email_consent' => sub {
        #email consent should be updated
        $email = sprintf('Test%.5f@deriv.com', rand(999));

        my $user = create_user($email);

        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $email,
            created_for => 'account_verification',
        )->token;

        $params->{args}->{email_consent} = 1;

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('If verification code is ok - account verified successfully');

        $user = BOM::User->new(email => $email);
        #user should be email verified
        ok($user->email_verified, 'User should be email verified');

        ok($user->email_consent, 'User should be email consented');

        #email consent should not be updated when verification code check fails
        $user->update_email_fields(email_consent => 0);

        $params->{args}->{verification_code} = 'wrong_token';

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InvalidToken', 'If email verification_code is wrong it should return error')
            ->error_message_is('Your token has expired or is invalid.', 'If email verification_code is wrong it should return error_message');

        ok(!$user->email_consent, 'User email consent should not be updated when token validation fails');

        #email consent should not be updated if email if already verified
        $user->update_email_fields(
            email_consent  => 0,
            email_verified => 1
        );

        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $email,
            created_for => 'account_verification',
        )->token;

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('UserAlreadyVerified', 'If user already email verified it should return error')
            ->error_message_is('User is already email verified.', 'If user already email verified it should return error_message');

        ok(!$user->email_consent, 'User email consent should not be updated when email is already verified');

    };

    subtest 'confirm_email full flow' => sub {
        my @emitted_event;
        no warnings 'redefine';
        local *BOM::Platform::Event::Emitter::emit = sub { push @emitted_event, @_ };

        for my $feature_flag (1, 0) {
            #Testing against feature flag
            BOM::Config::Runtime->instance->app_config->email_verification->suspend->virtual_accounts($feature_flag);

            my $email = 'test' . rand(999) . '@deriv.com';

            subtest 'non-existing user' => sub {
                $verify_email_args->{verify_email} = $email;
                $params->{args}                    = $verify_email_args;

                $rpc_ct->call_ok('verify_email', $params)->has_no_system_error->has_no_error->result_is_deeply($verify_email_expected_response,
                    "It always should return 1, so not to leak client's email");
                is scalar @emitted_event, 0, 'no email as user does not exist';
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
                $email = 'test' . rand(999) . '@deriv.com';
                $acc_args->{details}->{email} = $email;

                my $acc = BOM::Platform::Account::Virtual::create_account($acc_args);
                my ($vr_client, $user) = ($acc->{client}, $acc->{user});

                ok !$user->email_verified, 'User is not email verified';

                $verify_email_args->{verify_email} = $email;
                $params->{args}                    = $verify_email_args;

                $rpc_ct->call_ok('verify_email', $params)->has_no_system_error->has_no_error->result_is_deeply($verify_email_expected_response,
                    "It always should return 1, so not to leak client's email");
                is($emitted_event[1]->{email}, $email,                 'email is sent to user');
                is($emitted_event[0],          'account_verification', 'email type is account_verification');

                $confirm_email_args->{verification_code} = $emitted_event[1]->{code};
                $params->{args}                          = $confirm_email_args;

                $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('If verification code is ok - account verified successfully');

                $user = BOM::User->new(email => $email);
                #user should be email verified
                ok($user->email_verified, 'User should be email verified');

                #email consent should be updated
                ok($user->email_consent, 'User email consent should be updated');

                @emitted_event = ();
            };

            subtest 'exisiting user already email verified' => sub {
                $email = 'test' . rand(999) . '@deriv.com';

                $acc_args->{details}->{email} = $email;
                my $acc = BOM::Platform::Account::Virtual::create_account($acc_args);
                my ($vr_client, $user) = ($acc->{client}, $acc->{user});

                $user->update_email_fields(email_verified => 1);

                ok $user->email_verified, 'User is email verified';

                $verify_email_args->{verify_email} = $email;
                $params->{args}                    = $verify_email_args;

                $rpc_ct->call_ok('verify_email', $params)->has_no_system_error->has_no_error->result_is_deeply($verify_email_expected_response,
                    "It always should return 1, so not to leak client's email");
                isnt($emitted_event[1]->{email}, $email, 'email is not sent to user');

                @emitted_event = ();
            };

            subtest 'Incorrect code type from verify_email' => sub {
                $email = 'test' . rand(999) . '@deriv.com';
                $acc_args->{details}->{email} = $email;

                my $acc = BOM::Platform::Account::Virtual::create_account($acc_args);
                my ($vr_client, $user) = ($acc->{client}, $acc->{user});

                ok !$user->email_verified, 'User is not email verified';

                $verify_email_args->{verify_email} = $email;
                $verify_email_args->{type}         = 'account_opening';
                $params->{args}                    = $verify_email_args;

                $rpc_ct->call_ok('verify_email', $params)->has_no_system_error->has_no_error->result_is_deeply($verify_email_expected_response,
                    "It always should return 1, so not to leak client's email");

                is($emitted_event[1]->{properties}->{email}, $email, 'email is sent to user');
                isnt($emitted_event[0], 'account_verification', 'email type is not account_verification');

                $confirm_email_args->{verification_code} = $emitted_event[1]->{properties}->{code};
                $params->{args}                          = $confirm_email_args;

                $rpc_ct->call_ok($method, $params)
                    ->has_no_system_error->has_error->error_code_is('InvalidToken', 'If email verification_code type is wrong it should return error')
                    ->error_message_is('Your token has expired or is invalid.',
                    'If email verification_code type is wrong it should return error_message');

                ok(!$user->email_verified, 'User not email verified when token invalid');
                ok(!$user->email_consent,  'User email consent should not be updated when email is already verified');

                @emitted_event = ();
            };

            subtest 'Expired code from verify_email' => sub {
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

                $email = 'test' . rand(999) . '@deriv.com';
                $acc_args->{details}->{email} = $email;

                my $acc = BOM::Platform::Account::Virtual::create_account($acc_args);
                my ($vr_client, $user) = ($acc->{client}, $acc->{user});

                ok !$user->email_verified, 'User is not email verified';

                $verify_email_args->{verify_email} = $email;
                $verify_email_args->{type}         = 'account_verification';
                $params->{args}                    = $verify_email_args;

                $rpc_ct->call_ok('verify_email', $params)->has_no_system_error->has_no_error->result_is_deeply($verify_email_expected_response,
                    "It always should return 1, so not to leak client's email");
                use Data::Dump qw(pp);

                is($emitted_event[1]->{email}, $email,                 'email is sent to user');
                is($emitted_event[0],          'account_verification', 'email type is account_verification');

                $confirm_email_args->{verification_code} = $emitted_event[1]->{code};
                $params->{args}                          = $confirm_email_args;

                $rpc_ct->call_ok('confirm_email', $params)
                    ->has_no_system_error->has_error->error_code_is('InvalidToken', 'If email verification_code is expired it should return error')
                    ->error_message_is('Your token has expired or is invalid.',
                    'If email verification_code is expired it should return error_message');

                ok(!$user->email_verified, 'User not email verified when token invalid');
                ok(!$user->email_consent,  'User email consent should not be updated when token invalid');

                @emitted_event = ();
                $mock->unmock('create_token');
            };

        }
    }
};

done_testing();
