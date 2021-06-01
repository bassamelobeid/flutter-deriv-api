use strict;
use warnings;

use Test::Exception;
use Test::More;
use Test::Mojo;
use Test::Deep;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Token::API;
use BOM::Test::RPC::QueueClient;
use BOM::Test::Helper::Client qw(create_client);
use BOM::Test::Script::DevExperts;

use Test::BOM::RPC::Accounts;

my $c = BOM::Test::RPC::QueueClient->new();

my %emitted;
my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->mock(
    'emit',
    sub {
        my ($type, $data) = @_;
        $emitted{$type}++;
    });

BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts03->all(0);
BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p02_ts02->all(0);

my $method = 'trading_platform_password_change';
subtest 'setting up new trading password' => sub {
    # create client
    my $client = create_client('CR');
    $client->email('Test123@binary.com');
    $client->set_default_account('USD');
    $client->save;

    # create user
    my $password = 'Hello123';
    my $hash_pwd = BOM::User::Password::hashpw($password);
    my $user     = BOM::User->create(
        email    => 'Test123@binary.com',
        password => $hash_pwd,
    );
    $user->add_client($client);

    # can set a new trading_password
    my $token  = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            new_password => 'Abc',
            old_password => ''
        }};
    $c->call_ok($method, $params)->has_error->error_code_is('PasswordError')
        ->error_message_is('Your password must be 8 to 25 characters long. It must include lowercase and uppercase letters, and numbers.',
        'weak new password');

    $params->{args}{new_password} = 'Abcd1234';
    $params->{args}{old_password} = 'Hello123';
    $c->call_ok($method, $params)->has_error->error_code_is('NoOldPassword', 'cannot provide old password yet');

    # should fail if trading password = user password
    $params->{args}{new_password} = $user->email;
    delete $params->{args}{old_password};
    $c->call_ok($method, $params)->has_error->error_code_is('PasswordError')
        ->error_message_like(qr/cannot use your email address/, 'new password same as email');

    $params->{args}->{new_password} = 'Abcd1234';
    is($c->call_ok($method, $params)->has_no_error->result, 1, 'user trading password changed successfully');

    # ok $emitted{"trading_platform_password_reset_confirmation"}, "trading_platform_password_reset_confirmation event emitted";

    # should not allow setting new trading password if trading_password is already set
    $params->{args}->{new_password} = 'Efgh1234';
    $params->{args}->{old_password} = '';
    $c->call_ok($method, $params)->has_error->error_code_is('OldPasswordRequired');

    # should pass
    $params->{args}->{old_password} = 'Abcd1234';
    is($c->call_ok($method, $params)->has_no_error->result, 1, 'user trading password changed successfully');

    # is $emitted{"trading_platform_password_reset_confirmation"}, 2, "trading_platform_password_reset_confirmation event emitted";
};

# prepare mock mt5 accounts
@BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

my %accounts = %Test::BOM::RPC::Accounts::MT5_ACCOUNTS;
my %details  = %Test::BOM::RPC::Accounts::ACCOUNT_DETAILS;

# create user
my $password = 'Hello1234';
my $hash_pwd = BOM::User::Password::hashpw($password);
my $user     = BOM::User->create(
    email          => $details{email},
    password       => $hash_pwd,
    email_verified => 1
);

# create client
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    email          => $details{email},
    place_of_birth => 'id',
});
$client->set_default_account('USD');
$client->set_authentication('ID_DOCUMENT', {status => 'pass'});
$user->add_client($client);

my ($mt5_loginid, $mt5_demo_loginid);
subtest 'password change with mt5 accounts' => sub {
    # create mt5 account (for existing user with mt5 accounts - but no trading password)
    my $token      = BOM::Platform::Token::API->new->create_token($client->loginid, 'token');
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

    my $result = $c->call_ok('mt5_new_account', $mt5_params)->has_no_error('gaming account successfully created')->result;
    ok $result, 'no error for mt5_new_account';
    $mt5_loginid = $result->{login};
    is($mt5_loginid, 'MTR' . $accounts{'real\p01_ts03\synthetic\svg_std_usd\01'}, 'MT5 loginid is correct');

    BOM::RPC::v3::MT5::Account::reset_throttler($client->loginid);

    # create demo mt5 account
    $mt5_params->{args}->{account_type}     = 'demo';
    $mt5_params->{args}->{mt5_account_type} = 'financial';
    $result                                 = $c->call_ok('mt5_new_account', $mt5_params)->has_no_error('demo account successfully created')->result;
    ok $result, 'no error for mt5_new_account';
    $mt5_demo_loginid = $result->{login};
    is($mt5_demo_loginid, 'MTD' . $accounts{'demo\p01_ts01\financial\svg_std_usd'}, 'MT5 loginid is correct');

    ok BOM::User::Password::checkpw($details{password}{main}, $client->user->trading_password), 'correctly changed trading password';

    my $trading_password = 'Abcd1234';
    my $mock_mt5         = Test::MockModule->new('BOM::MT5::User::Async');
    $mock_mt5->mock(
        # mock mt5 password_change API
        password_change => sub {
            my ($data) = @_;
            if ($data->{new_password} eq $trading_password) {
                return Future->done(1);
            }
            return Future->fail({
                code => 'InvalidPassword',
            });
        },
        # mock mt5 password_check API
        password_check => sub {
            my ($status) = @_;
            if ($status->{password} ne $trading_password) {
                return Future->fail({
                    code  => 'InvalidPassword',
                    error => 'Invalid account password',
                });
            }
            return Future->done({status => 1});
        });

    # change trading password - now the mt5 account password should also changed
    my $params = {
        token => $token,
        args  => {
            new_password => $trading_password,
            old_password => 'what is my password',
        }};

    # should fail when using the wrong old password
    $c->call_ok($method, $params)->has_error->error_code_is('PasswordError')->error_message_is('Provided password is incorrect.');

    # should pass when using the correct old password
    $params->{args}->{old_password} = 'Efgh4567';

    is($c->call_ok($method, $params)->has_no_error->result, 1, 'user trading password changed successfully');

    # sanity check on trading password change :))
    ok BOM::User::Password::checkpw($trading_password, $client->user->trading_password), 'correctly changed trading password';

    # check that mt5 account password was also changed
    $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login    => $mt5_loginid,
            password => 'bla341',
            type     => 'main',
        },
    };

    $c->call_ok('mt5_password_check', $params)->has_error->error_code_is('InvalidPassword')->error_message_is('Invalid account password');

    $params->{args}->{password} = $trading_password;
    is($c->call_ok('mt5_password_check', $params)->has_no_error->result, 1, 'mt5 account password was changed successfully');

    $mock_mt5->unmock_all();

    # mock mt5 password_change call failure
    $mock_mt5->mock(
        password_change => sub {
            return Future->fail({
                error => '',
                code  => 'General',
            });
        });

    $params->{args}->{new_password} = 'Hello1234!@';
    $params->{args}->{old_password} = $trading_password;

    # $c->call_ok($method, $params)->has_error('has error for password_change')->error_code_is('General');

    ok BOM::User::Password::checkpw($trading_password, $client->user->trading_password), 'should not change trading password';

    $mock_mt5->unmock_all();
};

$method = 'trading_platform_password_reset';
subtest 'password reset with mt5 accounts' => sub {
    my $trading_password = 'Abcd1234@!';
    my $verification_code;

    my $mock_token = Test::MockModule->new('BOM::Platform::Token');
    $mock_token->mock(
        'token',
        sub {
            $verification_code = $mock_token->original('token')->(@_);
        });

    my $mock_mt5 = Test::MockModule->new('BOM::MT5::User::Async');
    $mock_mt5->mock(
        # mock mt5 password_change API
        password_change => sub {
            my ($data) = @_;
            if ($data->{new_password} eq $trading_password) {
                return Future->done(1);
            }
            return Future->fail({
                code => 'InvalidPassword',
            });
        },
        # mock mt5 password_check API
        password_check => sub {
            my ($status) = @_;

            if ($status->{password} ne $trading_password) {
                return Future->fail({
                    code  => 'InvalidPassword',
                    error => 'Invalid account password',
                });
            }

            return Future->done({status => 1});
        });

    my $params = {
        language => 'EN',
        args     => {
            verify_email => $details{email},
            type         => 'trading_platform_password_reset',
        }};

    $c->call_ok('verify_email', $params)->has_no_system_error->has_no_error->result_is_deeply({
            status => 1,
            stash  => {
                app_markup_percentage      => 0,
                valid_source               => 1,
                source_bypass_verification => 0
            },
        },
        'Verification code generated'
    );

    $params = {
        args => {
            new_password      => $trading_password,
            verification_code => $verification_code
        },
    };

    is($c->call_ok($method, $params)->has_no_error->result, 1, 'trading password reset successfully');

    # ok $emitted{"trading_platform_password_reset_confirmation"}, "trading_platform_password_reset_confirmation event emitted";

    ok BOM::User::Password::checkpw($trading_password, $client->user->trading_password), 'trading password reset ok';

    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'token');
    $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login    => $mt5_loginid,
            password => 'bla341',
            type     => 'main',
        },
    };

    # check that mt5 account password was also reset
    $c->call_ok('mt5_password_check', $params)->has_error->error_code_is('InvalidPassword')->error_message_is('Invalid account password');

    $params->{args}->{password} = $trading_password;
    is($c->call_ok('mt5_password_check', $params)->has_no_error->result, 1, 'mt5 account password was changed successfully');

    $mock_mt5->unmock_all();
    $mock_token->unmock_all();
};

$method = 'trading_platform_investor_password_reset';
subtest 'investor password change' => sub {
    my $investor_password = 'Abcd1234@!';
    my $verification_code;

    my $mock_token = Test::MockModule->new('BOM::Platform::Token');
    $mock_token->mock(
        'token',
        sub {
            $verification_code = $mock_token->original('token')->(@_);
        });

    my $mock_mt5 = Test::MockModule->new('BOM::MT5::User::Async');
    $mock_mt5->mock(
        # mock mt5 password_change API
        password_change => sub {
            my ($data) = @_;
            if ($data->{new_password} eq $investor_password) {
                return Future->done(1);
            }
            return Future->fail({
                code => 'InvalidPassword',
            });
        },
        # mock mt5 password_check API
        password_check => sub {
            my ($status) = @_;

            if ($status->{password} ne $investor_password) {
                return Future->fail({
                    code  => 'InvalidPassword',
                    error => 'Invalid account password',
                });
            }

            return Future->done({status => 1});
        });

    my $params = {
        language => 'EN',
        args     => {
            verify_email => $details{email},
            type         => 'trading_platform_investor_password_reset',
        }};

    $c->call_ok('verify_email', $params)->has_no_system_error->has_no_error->result_is_deeply({
            status => 1,
            stash  => {
                app_markup_percentage      => 0,
                valid_source               => 1,
                source_bypass_verification => 0
            },
        },
        'Verification code generated'
    );

    $params = {
        args => {
            account_id        => $mt5_loginid,
            platform          => 'mt5',
            new_password      => $investor_password,
            verification_code => $verification_code
        },
    };

    is($c->call_ok($method, $params)->has_no_error->result, 1, 'investor password reset successfully');

    $mock_mt5->unmock_all();
    $mock_token->unmock_all();
};

$method = 'trading_platform_investor_password_change';
subtest 'investor password change' => sub {
    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'token');

    my $params = {
        token => $token,
        args  => {
            account_id   => $mt5_loginid,
            new_password => 'InvestPwd123@',
            old_password => 'InvestPwd123@',
            platform     => 'mt5'
        }};

    # same password
    $c->call_ok($method, $params)->has_error->error_code_is('OldPasswordError')
        ->error_message_is("You've used this password before. Please create a different one.");

    # validate new investor password
    $params->{args}->{new_password} = 'BadPassword';
    $c->call_ok($method, $params)->has_error->error_code_is('IncorrectMT5PasswordFormat')
        ->error_message_is('Your password must be 8 to 25 characters long. It must include lowercase and uppercase letters, and numbers.');

    # wrong old password
    $params->{args}->{new_password} = 'InvestPwd123@!';
    $params->{args}->{old_password} = 'wrongPwd12@';
    $c->call_ok($method, $params)->has_error->error_code_is('InvalidPassword')->error_message_is('Forgot your password? Please reset your password.');

    # invalid mt5 login
    $params->{args}->{account_id} = 'MTR1203';
    $c->call_ok($method, $params)->has_error->error_code_is('MT5InvalidAccount')->error_message_is('An invalid MT5 account ID was provided.');

    my $mock_mt5 = Test::MockModule->new('BOM::MT5::User::Async');
    $mock_mt5->mock(
        # mock mt5 password_change API
        password_change => sub {
            my ($args) = @_;
            if ($args->{new_password} eq 'InvestPwd123@!') {
                return Future->done(1);
            }
            return Future->fail({
                code => 'InvalidPassword',
            });
        },
        # mock mt5 password_check API
        password_check => sub {
            my ($status) = @_;

            if ($status->{password} ne 'Abcd1234@!') {
                return Future->fail({
                    code  => 'InvalidPassword',
                    error => 'Invalid account password',
                });
            }

            return Future->done({status => 1});
        });

    $params->{args}->{account_id}   = $mt5_loginid;
    $params->{args}->{old_password} = 'Abcd1234@!';
    is($c->call_ok($method, $params)->has_no_error->result, 1, 'mt5 investor password was changed successfully');

    ok $emitted{"mt5_password_changed"}, "mt5_password_changed event emitted";

    $mock_mt5->unmock_all();
};

subtest 'partially changed password' => sub {
    my $token   = BOM::Platform::Token::API->new->create_token($client->loginid, 'token');
    my $new_pwd = 'Efgh1234!';

    my $mock_mt5 = Test::MockModule->new('BOM::MT5::User::Async');
    $mock_mt5->mock(
        get_user => sub {
            my ($login) = @_;
            if ($login eq $mt5_demo_loginid) {
                return Future->fail({code => 'NetworkIssue'});
            }
            return Future->done({login => $login});
        },
        password_change => sub {
            my ($data) = @_;
            if ($data->{new_password} eq $new_pwd) {
                if ($data->{login} eq $mt5_demo_loginid) {
                    return Future->fail({code => 'NetworkIssue'});
                }
                return Future->done({login => $data->{login}});
            }
            return Future->fail({
                code => 'InvalidPassword',
            });
        });

    my $params = {
        token => $token,
        args  => {
            new_password => $new_pwd,
            old_password => 'Abcd1234@!',
        }};

    my $error = $c->call_ok('trading_platform_password_change', $params)->result->{error};
    cmp_deeply(
        $error,
        {
            code              => 'PlatformPasswordChangeError',
            message_to_client =>
                "Due to a network issue, we're unable to update your trading password for the following account: $mt5_demo_loginid. Please wait for a few minutes before attempting to change your trading password for the above account.",
        },
        'returns correct error'
    );

    $mock_mt5->unmock_all();
};

$mock_events->unmock_all();

done_testing();
