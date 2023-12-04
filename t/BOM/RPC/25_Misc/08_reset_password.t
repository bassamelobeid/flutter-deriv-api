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

# Init db
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

# Check login of vrtc client
subtest 'check_login_vrtc' => sub {
    $status = $user_vr->login(password => $password);
    is $status->{success}, 1, 'vrtc login with current password OK';
};

my $new_password = 'jskjD8292923';

my $c = BOM::Test::RPC::QueueClient->new();

my @emitted;
my $mock_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_emitter->mock('emit' => sub { push @emitted, [@_]; });

my $expected_result = {
    status => 1,
    stash  => {
        app_markup_percentage      => 0,
        valid_source               => 1,
        source_bypass_verification => 0,
        source_type                => 'official',
    },
};

# Reset password vrtc
my $method = 'reset_password';
subtest 'reset_password_vrtc' => sub {
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
    is($emitted[0][1]->{properties}->{first_name}, 'bRaD',                        'first name is correct');
    is($emitted[0][1]->{properties}->{type},       'reset_password',              'type is correct');
    is($emitted[0][1]->{loginid},                  'VRTC1002',                    'loginid is correct');
    is($emitted[0][0],                             'reset_password_confirmation', 'event name is correct');
    ok @emitted, 'reset password event emitted correctly';
};

# Refetch vrtc user
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

# Check login of cr client
subtest 'check_login_cr' => sub {
    $status = $user_cr->login(password => $password);
    is $status->{success}, 1, 'cr login with current password OK';
};

# Reset password cr
subtest $method => sub {
    undef @emitted;
    my $params = {
        args => {
            new_password      => 'Weakpassword',
            verification_code => 123456
        }};

    # Test reset password with invalid verification code
    $c->call_ok($method, $params)->has_error->error_message_is('Your token has expired or is invalid.', 'InvalidToken');

    # Test reset password with a weak password, set up a valid token
    $code = BOM::Platform::Token->new({
            email       => $email_cr,
            expires_in  => 3600,
            created_for => 'reset_password'
        })->token;
    $params->{args}->{verification_code} = $code;
    $c->call_ok($method, $params)
        ->has_error->error_message_is('Your password must be 8 to 25 characters long. It must include lowercase and uppercase letters, and numbers.',
        'PasswordError');

    # Reset password with email as password
    $code = BOM::Platform::Token->new({
            email       => $email_cr,
            expires_in  => 3600,
            created_for => 'reset_password'
        })->token;
    $params->{args}->{verification_code} = $code;
    $params->{args}->{new_password}      = 'Abc1@binary.com';
    $c->call_ok($method, $params)->has_error->error_message_is('You cannot use your email address as your password.', 'PasswordError');

    # Test reset password with wrong DOB arg
    # - it should be ignored as the DOB was removed from the API function
    $code = BOM::Platform::Token->new({
            email       => $email_cr,
            expires_in  => 3600,
            created_for => 'reset_password'
        })->token;
    $params->{args}->{verification_code} = $code;
    $params->{args}->{new_password}      = $new_password;
    $params->{args}->{date_of_birth}     = '1991-01-01';
    $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result);

    # Test reset password is successful with correct args
    $code = BOM::Platform::Token->new({
            email       => $email_cr,
            expires_in  => 3600,
            created_for => 'reset_password'
        })->token;
    $params->{args}->{verification_code} = $code;
    delete $params->{args}->{date_of_birth};
    $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result);
    is($emitted[0][1]->{properties}->{first_name}, 'bRaD',                        'first name is correct');
    is($emitted[0][1]->{properties}->{type},       'reset_password',              'type is correct');
    is($emitted[0][1]->{loginid},                  'CR10000',                     'loginid is correct');
    is($emitted[0][0],                             'reset_password_confirmation', 'event name is correct');
    ok @emitted, 'reset password event emitted correctly';

    # Re-fetch cr user
    subtest 'check_password' => sub {
        $user_cr = $test_client_cr->user;
        $status  = $user_cr->login(password => $new_password);
        is $status->{success}, 1, 'cr login with new password OK';
    };
};

done_testing();
