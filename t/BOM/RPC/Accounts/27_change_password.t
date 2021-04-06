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
my $email       = 'abc@binary.com';
my $password    = 'Abcd33!@';
my $hash_pwd    = BOM::User::Password::hashpw($password);
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

my $test_client_disabled = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});

$test_client_disabled->status->set('disabled', 1, 'test disabled');

my $m              = BOM::Platform::Token::API->new;
my $token          = $m->create_token($test_client->loginid,          'test token');
my $token_disabled = $m->create_token($test_client_disabled->loginid, 'test token');

my $c = Test::BOM::RPC::QueueClient->new();

my $method = 'change_password';
subtest 'change password' => sub {
    my $oldpass = '1*VPB0k.BCrtHeWoH8*fdLuwvoqyqmjtDF2FfrUNO7A0MdyzKkelKhrc7MQjNQ=';
    is(
        BOM::RPC::v3::Utility::check_password({
                old_password => 'old_password',
                new_password => 'new_password',
                user_pass    => '1*VPB0k.BCrtHeWoH8*fdLuwvoqyqmjtDF2FfrUNO7A0MdyzKkelKhrc7MQjPQ='
            }
        )->{error}->{message_to_client},
        'Provided password is incorrect.',
        'Provided password is incorrect.',
    );
    is(
        BOM::RPC::v3::Utility::check_password({
                old_password => 'old_password',
                new_password => 'old_password',
                user_pass    => $oldpass
            }
        )->{error}->{message_to_client},
        'Current password and new password cannot be the same.',
        'Current password and new password cannot be the same.',
    );
    is(
        BOM::RPC::v3::Utility::check_password({
                old_password => 'old_password',
                new_password => 'water',
                user_pass    => $oldpass
            }
        )->{error}->{message_to_client},
        'Your password must be 8 to 25 characters long. It must include lowercase and uppercase letters, and numbers.',
        'Your password must be 8 to 25 characters long. It must include lowercase and uppercase letters, and numbers.',
    );
    is(
        BOM::RPC::v3::Utility::check_password({
                old_password => 'old_password',
                new_password => 'New#_p$ssword',
                user_pass    => $oldpass
            }
        )->{error}->{message_to_client},
        'Your password must be 8 to 25 characters long. It must include lowercase and uppercase letters, and numbers.',
        'no number.',
    );
    is(
        BOM::RPC::v3::Utility::check_password({
                old_password => 'old_password',
                new_password => 'pa$5A',
                user_pass    => $oldpass
            }
        )->{error}->{message_to_client},
        'Your password must be 8 to 25 characters long. It must include lowercase and uppercase letters, and numbers.',
        'too short.',
    );
    is(
        BOM::RPC::v3::Utility::check_password({
                old_password => 'old_password',
                new_password => 'pass$5ss',
                user_pass    => $oldpass
            }
        )->{error}->{message_to_client},
        'Your password must be 8 to 25 characters long. It must include lowercase and uppercase letters, and numbers.',
        'no upper case.',
    );
    is(
        BOM::RPC::v3::Utility::check_password({
                old_password => 'old_password',
                new_password => 'PASS$5SS',
                user_pass    => $oldpass
            }
        )->{error}->{message_to_client},
        'Your password must be 8 to 25 characters long. It must include lowercase and uppercase letters, and numbers.',
        'no lower case.',
    );
    is(
        BOM::RPC::v3::Utility::check_password({
                email        => 'abc1@binary.com',
                old_password => 'old_password',
                new_password => 'ABC1@binary.com',
                user_pass    => $oldpass
            }
        )->{error}->{message_to_client},
        'You cannot use your email address as your password.',
        'password must not be the same as email',
    );
    is($c->tcall($method, {token => '12345'})->{error}{message_to_client}, 'The token is invalid.', 'invalid token error');
    is(
        $c->tcall(
            $method,
            {
                token => undef,
            }
        )->{error}{message_to_client},
        'The token is invalid.',
        'invlaid token error'
    );
    isnt(
        $c->tcall(
            $method,
            {
                token => $token,
            }
        )->{error}{message_to_client},
        'The token is invalid.',
        'no token error if token is valid'
    );
    is(
        $c->tcall(
            $method,
            {
                token => $token_disabled,
            }
        )->{error}{message_to_client},
        'This account is unavailable.',
        'check authorization'
    );

    is($c->tcall($method, {})->{error}{message_to_client}, 'The token is invalid.', 'invalid token error');
    is(
        $c->tcall(
            $method,
            {
                token => $token_disabled,
            }
        )->{error}{message_to_client},
        'This account is unavailable.',
        'need a valid client'
    );
    my $params = {
        token => $token,
    };
    is($c->tcall($method, $params)->{error}{message_to_client}, 'Permission denied.', 'need token_type');
    $params->{token_type} = 'hello';
    is($c->tcall($method, $params)->{error}{message_to_client}, 'Permission denied.', 'need token_type');
    $params->{token_type}         = 'oauth_token';
    $params->{args}{old_password} = 'old_password';
    $params->{cs_email}           = 'cs@binary.com';
    $params->{client_ip}          = '127.0.0.1';
    is($c->tcall($method, $params)->{error}{message_to_client}, 'Provided password is incorrect.');
    $params->{args}{old_password} = $password;
    $params->{args}{new_password} = $password;
    is($c->tcall($method, $params)->{error}{message_to_client}, 'Current password and new password cannot be the same.');
    $params->{args}{new_password} = '111111111';
    is($c->tcall($method, $params)->{error}{message_to_client},
        'Your password must be 8 to 25 characters long. It must include lowercase and uppercase letters, and numbers.');
    my $new_password = 'Fsfjxljfwkls3@fs9';
    $params->{args}{new_password} = $new_password;
    mailbox_clear();
    is($c->tcall($method, $params)->{status}, 1, 'update password correctly');
    my $subject = 'Your new Deriv account password';
    my $msg     = mailbox_search(
        email   => $email,
        subject => qr/\Q$subject\E/
    );
    ok($msg, "email received");
    $user = BOM::User->new(id => $user->{id});
    isnt($user->{password}, $hash_pwd, 'user password updated');
    $test_client->load;
    isnt($user->{password}, $hash_pwd, 'client password updated');
    $password = $new_password;
};

subtest 'change_password - universal password' => sub {
    @BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

    my %accounts = %Test::BOM::RPC::Accounts::MT5_ACCOUNTS;
    my %details  = %Test::BOM::RPC::Accounts::ACCOUNT_DETAILS;

    my $password = 'Abcd1234';
    my $hash_pwd = BOM::User::Password::hashpw($password);
    my $user     = BOM::User->create(
        email          => $details{email},
        password       => $hash_pwd,
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

    my $result = $c->tcall('mt5_new_account', $mt5_params);
    ok $result, 'no error for mt5_new_account';
    my $mt5_loginid = $result->{login};
    is($mt5_loginid, 'MTR' . $accounts{'real\p01_ts03\synthetic\svg_std_usd\01'}, 'MT5 loginid is correct: ' . $mt5_loginid);

    BOM::Config::Runtime->instance->app_config->system->suspend->universal_password(0);    # enable universal password

    my $new_password = 'Ijkl6789';
    my $oauth_token  = $m->create_token($test_client->loginid, 'test token');
    my $params       = {
        token      => $oauth_token,
        token_type => 'oauth_token',
        args       => {
            old_password => $password,
            new_password => $new_password,
        }};

    is($c->tcall($method, $params)->{status}, 1, 'update password correctly');
    my $subject = "You've changed your password";
    my $msg     = mailbox_search(
        email   => $details{email},
        subject => qr/\Q$subject\E/
    );
    ok($msg, "email received");

    subtest 'check client status' => sub {
        my $params = {
            token => $oauth_token,
        };
        cmp_deeply(
            $c->tcall('get_account_status', $params)->{status},
            noneof(qw(password_reset_required)),
            'account doesn\'t have password_reset_required status'
        );
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

        is($c->tcall('mt5_password_check', $params)->{error}{message_to_client}, 'Invalid account password', 'InvalidPassword error');

        $params->{args}->{password} = $new_password;
        is($c->tcall('mt5_password_check', $params), 1, 'no error for mt5_password_check');

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

        my $new_password = 'Jolly123';
        my $oauth_token  = $m->create_token($test_client->loginid, 'test token');
        my $params       = {
            token      => $oauth_token,
            token_type => 'oauth_token',
            args       => {
                old_password => 'Ijkl6789',
                new_password => $new_password,
            }};

        is($c->tcall($method, $params)->{error}{code}, 'PasswordChangeError', 'Correct error code');

        is $test_client->user->login(password => $new_password)->{error},
            'Your email and/or password is incorrect. Please check and try again. Perhaps you signed up with a social account?',
            'Cannot login with new password';

        ok $test_client->user->login(password => 'Ijkl6789')->{success}, 'user password should remain unchanged';

        $mock_mt5->unmock_all();
    };

    BOM::Config::Runtime->instance->app_config->system->suspend->universal_password(1);    # disable universal password
};

done_testing();
