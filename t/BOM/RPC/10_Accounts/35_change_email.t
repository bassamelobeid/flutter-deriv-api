use strict;
use warnings;

use utf8;
use Test::More;
use Test::Deep;
use Test::Mojo;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use Email::Address::UseXS;
use BOM::Test::Email qw(:no_event);
use BOM::Platform::Token::API;
use BOM::Test::Helper::Token;
use Test::BOM::RPC::QueueClient;
use Test::BOM::RPC::Accounts;

BOM::Test::Helper::Token::cleanup_redis_tokens();

# init db
my $email    = 'abc@nowhere.com';
my $password = 'Aer13';
my $hash_pwd = BOM::User::Password::hashpw($password);

my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});

$test_client->email($email);
$test_client->save;

my $user = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);
$user->add_client($test_client);
$user->update_has_social_signup(0);

my $test_client_disabled = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});

my $m              = BOM::Platform::Token::API->new;
my $token          = $m->create_token($test_client->loginid,          'test token');
my $token_disabled = $m->create_token($test_client_disabled->loginid, 'test token');

my $c = Test::BOM::RPC::QueueClient->new();

my @emitted;
my $mock_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_emitter->mock('emit' => sub { push @emitted, [@_]; });

my $method = 'change_email';
subtest 'change email' => sub {
    my $new_email    = 'anyemail@xyz.com';
    my $new_password = 'Fsfjxljfwkls3@fs9';
    my $params       = {
        token => $token,
    };

    $params->{token_type}         = 'oauth_token';
    $params->{source}             = '1';
    $params->{cs_email}           = 'cs@binary.com';
    $params->{client_ip}          = '127.0.0.1';
    $params->{args}{change_email} = 'verify';

    $params->{args}{new_email}         = $email;
    $params->{args}{verification_code} = 'HIIAMCODE';

    my $result = $c->tcall($method, $params);
    my $error  = {
        'error' => {
            'code'              => 'InvalidToken',
            'message_to_client' => 'Your token has expired or is invalid.'
        }};
    is_deeply($result, $error, 'change_email returns token error');

    my $code = BOM::Platform::Token->new({
            email       => $email,
            expires_in  => 3600,
            created_for => 'request_email'
        })->token;
    $params->{args}{verification_code} = $code;
    $result                            = $c->tcall($method, $params);
    $error                             = {
        'error' => {
            'code'              => 'EmailBased',
            'message_to_client' => 'We can not seem to find your social account. If you need help with logging in, contact us.'
        }};
    is_deeply($result, $error, 'change_email returns token error');

    $user->update_has_social_signup(1);
    $code = BOM::Platform::Token->new({
            email       => $email,
            expires_in  => 3600,
            created_for => 'request_email'
        })->token;
    $params->{args}{verification_code} = $code;
    $result                            = $c->tcall($method, $params);
    $error                             = {
        'error' => {
            'code'              => 'InvalidEmail',
            'message_to_client' => 'This email is already in use. Please use a different email.'
        }};
    is_deeply($result, $error, 'change_email returns email error');

    $code = BOM::Platform::Token->new({
            email       => $email,
            expires_in  => 3600,
            created_for => 'request_email'
        })->token;
    $params->{args}{new_email}         = $email;
    $params->{args}{verification_code} = $code;

    $result = $c->tcall($method, $params);
    is_deeply($result, $error, 'change_email returns email error');

    $code = BOM::Platform::Token->new({
            email       => $email,
            expires_in  => 3600,
            created_for => 'request_email'
        })->token;
    $params->{args}{new_email}         = $new_email;
    $params->{args}{verification_code} = $code;

    $result = $c->tcall($method, $params);
    is($result->{status},                          1,                     'change_email returns 1');
    is($emitted[0][1]->{properties}->{first_name}, 'bRaD',                'first name is correct');
    is($emitted[0][1]->{loginid},                  'MF90000000',          'loginid is correct');
    is($emitted[0][0],                             'verify_change_email', 'event name is correct');
    ok @emitted, 'request_email event emitted correctly';

    $params->{args}{change_email}      = 'update';
    $params->{args}{new_email}         = $new_email;
    $params->{args}{new_password}      = $new_password;
    $params->{args}{verification_code} = 'dsf213';

    $result = $c->tcall($method, $params);
    $error  = {
        'error' => {
            'code'              => 'InvalidToken',
            'message_to_client' => 'Your token has expired or is invalid.'
        }};
    is_deeply($result, $error, 'change_email returns token error');

    $code = BOM::Platform::Token->new({
            email       => $new_email,
            expires_in  => 3600,
            created_for => 'request_email',
        })->token;
    $params->{args}{change_email}      = 'update';
    $params->{args}{new_email}         = $new_email;
    $params->{args}{new_password}      = 'easypassword';
    $params->{args}{verification_code} = $code;
    $result                            = $c->tcall($method, $params);
    $error                             = {
        'error' => {
            'code'              => 'PasswordError',
            'message_to_client' => 'Your password must be 8 to 25 characters long. It must include lowercase and uppercase letters, and numbers.'
        }};
    is_deeply($result, $error, 'change_email returns password error');

    $code = BOM::Platform::Token->new({
            email       => $new_email,
            expires_in  => 3600,
            created_for => 'request_email',
        })->token;
    $params->{args}{change_email}      = 'update';
    $params->{args}{new_email}         = $new_email;
    $params->{args}{new_password}      = undef;
    $params->{args}{verification_code} = $code;
    $result                            = $c->tcall($method, $params);
    is_deeply($result, $error, 'change_email returns password error');

    $code = BOM::Platform::Token->new({
            email       => $new_email,
            expires_in  => 3600,
            created_for => 'request_email',
        })->token;
    $params->{args}{change_email}      = 'update';
    $params->{args}{new_email}         = $new_email;
    $params->{args}{new_password}      = $new_password;
    $params->{args}{verification_code} = $code;
    $result                            = $c->tcall($method, $params);

    is($result->{status},         1,                  'change_email returns 1');
    is($emitted[1][1]->{loginid}, 'MF90000000',       'loginid is correct');
    is($emitted[1][0],            'sync_user_to_MT5', 'event name is correct');

    is($emitted[2][1]->{loginid}, 'MF90000000',          'loginid is correct');
    is($emitted[2][0],            'sync_onfido_details', 'event name is correct');

    is($emitted[3][1]->{properties}->{first_name}, 'bRaD',                 'first name is correct');
    is($emitted[3][1]->{loginid},                  'MF90000000',           'loginid is correct');
    is($emitted[3][0],                             'confirm_change_email', 'event name is correct');

    $user = BOM::User->new(id => $user->{id});
    isnt($user->{password}, $hash_pwd, 'user password updated');

    $test_client->load;
    isnt($user->{password}, $hash_pwd, 'client password updated');

    $password = $new_password;
    isnt($user->{email},                         $email, 'users email updated');
    isnt($test_client->get_mt5_details->{email}, $email, 'mt5\'s user email updated');
};

done_testing();
