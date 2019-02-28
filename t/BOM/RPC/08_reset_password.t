use strict;
use warnings;
use BOM::Test::RPC::Client;
use Test::More;
use Test::Mojo;
use Email::Address::UseXS;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Email;
use BOM::User;
use utf8;
use BOM::Platform::Token;

# init db
my $email_vr = 'abv@binary.com';
my $email_cr = 'abc@binary.com';
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

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);

my $expected_result = {
    status => 1,
    stash  => {
        app_markup_percentage => '0',
        valid_source          => 1
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
    $status = $user_vr->login(password => $new_password);
    is $status->{success}, 1, 'vrtc login with new password OK';
};

my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code   => 'CR',
    date_of_birth => $dob,
});
$test_client_cr->email($email_cr);
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
        ->has_error->error_message_is('Password should be at least six characters, including lower and uppercase letters with numbers.',
        'PasswordError');

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
};

# refetch cr user
subtest 'check_password' => sub {
    $user_cr = $test_client_cr->user;
    $status = $user_cr->login(password => $new_password);
    is $status->{success}, 1, 'cr login with new password OK';
};
done_testing();
