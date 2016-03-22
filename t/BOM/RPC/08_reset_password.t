use strict;
use warnings;
use Test::BOM::RPC::Client;
use Test::Most;
use Test::Mojo;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Platform::User;
use BOM::Platform::SessionCookie;
use utf8;
use BOM::Platform::Token::Verification;

# init db
my $email    = 'abc@binary.com';
my $password = 'jskjd8292922';
my $hash_pwd = BOM::System::Password::hashpw($password);
my $dob      = '1990-07-09';

my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code   => 'CR',
    date_of_birth => $dob,
});
$test_client_cr->email($email);
$test_client_cr->save;
my $test_loginid = $test_client_cr->loginid;

my $user = BOM::Platform::User->create(
    email    => $email,
    password => $hash_pwd
);
$user->save;
$user->add_loginid({loginid => $test_loginid});
$user->save;
my $status;

# check login
subtest 'check_login' => sub {
    $status = $user->login(password => $password);
    is $status->{success}, 1, 'login with current password OK';
};

my $code = BOM::Platform::Token::Verification->new({
        email       => $email,
        expires_in  => 3600,
        created_for => 'reset_password'
    })->token;

my $new_password = 'jskjD8292923';

my $c = Test::BOM::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);

# reset password
my $method = 'reset_password';
subtest $method => sub {
    my $params = {
        args => {
            new_password      => 'Weakpassword',
            date_of_birth     => '1991-01-01',
            verification_code => 123456
        }};

    # reset password with invalid verification code
    $c->call_ok($method, $params)->has_error->error_message_is('Your token has expired.', 'InvalidToken');

    $params->{args}->{verification_code} = $code;
    # reset password with weak password
    $c->call_ok($method, $params)
        ->has_error->error_message_is('Password should be at least six characters, including lower and uppercase letters with numbers.',
        'PasswordError');

    $code = BOM::Platform::Token::Verification->new({
            email       => $email,
            expires_in  => 3600,
            created_for => 'reset_password'
        })->token;
    $params->{args}->{verification_code} = $code;
    $params->{args}->{new_password}      = $new_password;

    # reset password with wrong date of birth
    $c->call_ok($method, $params)->has_error->error_message_is('The email address and date of birth do not match.', 'DateOfBirthMismatch');
    $params->{args}->{date_of_birth} = $dob;
    $code = BOM::Platform::Token::Verification->new({
            email       => $email,
            expires_in  => 3600,
            created_for => 'reset_password'
        })->token;
    $params->{args}->{verification_code} = $code;

    $c->call_ok($method, $params)->has_no_error->result_is_deeply({status => 1});
};

# refetch user
subtest 'check_password' => sub {
    $user = BOM::Platform::User->new({
        email => $email,
    });
    $status = $user->login(password => $new_password);
    is $status->{success}, 1, 'login with new password OK';
};

done_testing();
