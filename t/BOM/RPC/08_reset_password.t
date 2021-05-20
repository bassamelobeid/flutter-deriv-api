use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Test::Deep;
use Test::BOM::RPC::Accounts;
use Email::Address::UseXS;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::RPC::QueueClient;
use BOM::Test::Email qw(:no_event);
use BOM::User;
use utf8;
use BOM::Platform::Token;

# init db
my $email_vr = 'abv@binary.com';
my $email_cr = 'abc1@binary.com';
my $password = 'jskjd8292922';
my $hash_pwd = BOM::User::Password::hashpw($password);
my $dob      = '1990-07-09';

my $test_client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code   => 'VRTC',
    date_of_birth => undef,
});
$test_client_vr->email($email_vr);
$test_client_vr->save;
my $test_loginid_vr = $test_client_vr->loginid;

my $user_vr = BOM::User->create(
    email    => $email_vr,
    password => $hash_pwd
);
$user_vr->add_client($test_client_vr);

my ($status, $code);

# check login of vrtc client
subtest 'check_login_vrtc' => sub {
    $status = $user_vr->login(password => $password);
    is $status->{success}, 1, 'vrtc login with current password OK';
};

my $new_password = 'jskjD8292923';

my $c = BOM::Test::RPC::QueueClient->new();

my $expected_result = {
    status => 1,
    stash  => {
        app_markup_percentage      => 0,
        valid_source               => 1,
        source_bypass_verification => 0
    },
};

# reset password vrtc
my $method = 'reset_password';
subtest 'reset_password_vrtc' => sub {
    mailbox_clear;
    $code = BOM::Platform::Token->new({
            email       => $email_vr,
            expires_in  => 3600,
            created_for => 'reset_password'
        })->token;

    my $params = {
        args => {
            new_password      => $new_password,
            verification_code => $code
        }};

    $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result);

    my $subject = 'Your password has been reset.';
    my $msg     = mailbox_search(
        email   => $email_vr,
        subject => qr/\Q$subject\E/
    );
    ok($msg, "email received");
};

# refetch vrtc user
subtest 'check_password' => sub {
    $user_vr = $test_client_vr->user;
    $status  = $user_vr->login(password => $new_password);
    is $status->{success}, 1, 'vrtc login with new password OK';
};

my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code   => 'CR',
    date_of_birth => $dob,
});
$test_client_cr->email($email_cr);
$test_client_cr->set_default_account('USD');
$test_client_cr->save;
my $test_loginid_cr = $test_client_cr->loginid;

my $user_cr = BOM::User->create(
    email    => $email_cr,
    password => $hash_pwd
);
$user_cr->add_client($test_client_cr);

# check login of cr client
subtest 'check_login_cr' => sub {
    $status = $user_cr->login(password => $password);
    is $status->{success}, 1, 'cr login with current password OK';
};

# reset password cr
subtest $method => sub {
    my $params = {
        args => {
            new_password      => 'Weakpassword',
            date_of_birth     => $dob,
            verification_code => 123456
        }};

    # reset password with invalid verification code
    $c->call_ok($method, $params)->has_error->error_message_is('Your token has expired or is invalid.', 'InvalidToken');

    $code = BOM::Platform::Token->new({
            email       => $email_cr,
            expires_in  => 3600,
            created_for => 'reset_password'
        })->token;
    $params->{args}->{verification_code} = $code;

    # reset password with weak password
    $c->call_ok($method, $params)
        ->has_error->error_message_is('Your password must be 8 to 25 characters long. It must include lowercase and uppercase letters, and numbers.',
        'PasswordError');

    $code = BOM::Platform::Token->new({
            email       => $email_cr,
            expires_in  => 3600,
            created_for => 'reset_password'
        })->token;
    $params->{args}->{verification_code} = $code;

    # reset password with email as password
    $params->{args}->{new_password} = 'Abc1@binary.com';
    $c->call_ok($method, $params)->has_error->error_message_is('You cannot use your email address as your password.', 'PasswordError');

    $code = BOM::Platform::Token->new({
            email       => $email_cr,
            expires_in  => 3600,
            created_for => 'reset_password'
        })->token;
    $params->{args}->{verification_code} = $code;
    $params->{args}->{new_password}      = $new_password;
    $params->{args}->{date_of_birth}     = '1991-01-01';

    # reset password with wrong date of birth
    $c->call_ok($method, $params)->has_error->error_message_is('The email address and date of birth do not match.', 'DateOfBirthMismatch');
    $params->{args}->{date_of_birth} = $dob;
    $code = BOM::Platform::Token->new({
            email       => $email_cr,
            expires_in  => 3600,
            created_for => 'reset_password'
        })->token;
    $params->{args}->{verification_code} = $code;

    mailbox_clear();
    $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result);
    my $subject = 'Your password has been reset.';
    my $msg     = mailbox_search(
        email   => $email_cr,
        subject => qr/\Q$subject\E/
    );
    ok($msg, "email received");

    # Should reset password if DOB is not provided
    $code = BOM::Platform::Token->new({
            email       => $email_cr,
            expires_in  => 3600,
            created_for => 'reset_password'
        })->token;
    $params->{args}->{verification_code} = $code;
    $params->{args}->{new_password}      = $new_password;
    delete $params->{args}->{date_of_birth};

    mailbox_clear();
    $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result);
    ok($msg, "email received");

    # refetch cr user
    subtest 'check_password' => sub {
        $user_cr = $test_client_cr->user;
        $status  = $user_cr->login(password => $new_password);
        is $status->{success}, 1, 'cr login with new password OK';
    };
};

subtest 'reset_password - universal password' => sub {
    @BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

    my %accounts = %Test::BOM::RPC::Accounts::MT5_ACCOUNTS;
    my %details  = %Test::BOM::RPC::Accounts::ACCOUNT_DETAILS;

    my $user = BOM::User->create(
        email          => $details{email},
        password       => 'Abcd1234',
        email_verified => 1
    );

    my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $details{email},
        place_of_birth => 'id',
    });
    $test_client->set_default_account('USD');
    $test_client->set_authentication('ID_DOCUMENT', {status => 'pass'});
    $user->add_client($test_client);

    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts03->all(0);

    my $token = BOM::Platform::Token::API->new->create_token($test_client->loginid, 'token');

    my $mt5_params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type => 'gaming',
            country      => 'mt',
            email        => $details{email},
            name         => $details{name},
            mainPassword => $details{password}{main},
            leverage     => 100,
        }};

    $c->call_ok('mt5_new_account', $mt5_params)->has_no_error('no error for mt5_new_account');
    my $mt5_loginid = $c->result->{login};
    is($mt5_loginid, 'MTR' . $accounts{'real\p01_ts03\synthetic\svg_std_usd\01'}, 'MT5 loginid is correct: ' . $mt5_loginid);

    BOM::Config::Runtime->instance->app_config->system->suspend->universal_password(0);    # enable universal password

    my $new_password = 'Ijkl6789';
    my $code         = BOM::Platform::Token->new({
            email       => $details{email},
            expires_in  => 3600,
            created_for => 'reset_password'
        })->token;
    my $reset_password_params = {
        args => {
            new_password      => $new_password,
            verification_code => $code
        }};

    $c->call_ok('reset_password', $reset_password_params)->has_no_error->result_is_deeply($expected_result);

    my $subject = "You've set your password";
    my $msg     = mailbox_search(
        email   => $details{email},
        subject => qr/\Q$subject\E/
    );
    ok($msg, "email received");

    # refetch cr user
    subtest 'check_password' => sub {
        $user   = $test_client->user;
        $status = $user->login(password => $new_password);
        ok $status->{success}, 'cr login with new password OK';
    };

    subtest 'check client status' => sub {
        my $params = {
            token => $token,
        };

        $c->call_ok('get_account_status', $params);
        cmp_deeply($c->result->{status}, noneof(qw(password_reset_required)), 'account doesn\'t have password_reset_required status');
    };

    subtest 'mt5_password_check' => sub {
        my $mock_mt5 = Test::MockModule->new('BOM::MT5::User::Async');
        $mock_mt5->mock(
            password_check => sub {
                my ($status) = @_;

                if ($status->{password} ne 'Ijkl6789') {
                    return Future->fail({
                        code  => 'InvalidPassword',
                        error => 'Invalid account password',
                    });
                }

                return Future->done({status => 1});
            });

        my $params = {
            language => 'EN',
            token    => $token,
            args     => {
                login    => $mt5_loginid,
                password => 'bla341',
                type     => 'main',
            },
        };
        $c->call_ok('mt5_password_check', $params)->has_error->error_message_is('Invalid account password', 'InvalidPassword');

        $params->{args}->{password} = $new_password;
        $c->call_ok('mt5_password_check', $params)->has_no_error('no error for mt5_password_check');

        $mock_mt5->unmock_all();
    };

    subtest 'MT5 call fails - NoConnection' => sub {
        my $mock_mt5 = Test::MockModule->new('BOM::MT5::User::Async');
        $mock_mt5->mock(
            password_change => sub {
                return Future->fail({
                    error => 'NoConnection',
                    code  => 'NoConnection',
                });
            });

        my $code = BOM::Platform::Token->new({
                email       => $details{email},
                expires_in  => 3600,
                created_for => 'reset_password'
            })->token;
        my $params = {
            args => {
                new_password      => 'Jolly123',
                verification_code => $code
            }};

        $c->call_ok('reset_password', $params)->error_code_is('PasswordResetError');

        is $test_client->user->login(password => 'Jolly123')->{error},
            'Your email and/or password is incorrect. Perhaps you signed up with a social account?',
            'Cannot login with new password';

        ok $test_client->user->login(password => $new_password)->{success}, 'user password should remain unchanged';

        $mock_mt5->unmock_all();
    };

    BOM::Config::Runtime->instance->app_config->system->suspend->universal_password(1);    # disable universal password
};

done_testing();
