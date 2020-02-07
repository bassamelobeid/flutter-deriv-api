use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::Mojo;
use Test::MockModule;

use BOM::Test::RPC::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Helper::Client qw(create_client top_up);
use BOM::Test::Email qw(:no_event);

use LandingCompany::Registry;
use BOM::MT5::User::Async;
use BOM::Platform::Token;
use BOM::User;

use Test::BOM::RPC::Accounts;

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC::Transport::HTTP')->app->ua);

@BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

my %ACCOUNTS = %Test::BOM::RPC::Accounts::MT5_ACCOUNTS;
my %DETAILS  = %Test::BOM::RPC::Accounts::ACCOUNT_DETAILS;

my %emitted;
my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->mock(
    'emit',
    sub {
        my ($type, $data) = @_;
        $emitted{$type}++;
    });

# Setup a test user
my $test_client = create_client('CR');
$test_client->email($DETAILS{email});
$test_client->set_default_account('USD');
$test_client->binary_user_id(1);

$test_client->set_authentication('ID_DOCUMENT')->status('pass');
$test_client->save;

my $user = BOM::User->create(
    email    => $DETAILS{email},
    password => 's3kr1t',
);
$user->add_client($test_client);

my $m = BOM::Platform::Token::API->new;
my $token = $m->create_token($test_client->loginid, 'test token');

# Throttle function limits requests to 1 per minute which may cause
# consecutive tests to fail without a reset.
BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

my $params = {
    language => 'EN',
    token    => $token,
    args     => {
        account_type => 'gaming',
        country      => 'mt',
        email        => $DETAILS{email},
        name         => $DETAILS{name},
        mainPassword => $DETAILS{password}{main},
        leverage     => 100,
    },
};
$c->call_ok('mt5_new_account', $params)->has_no_error('no error for mt5_new_account');

subtest 'get settings' => sub {
    my $method = 'mt5_get_settings';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login => 'MTR' . $ACCOUNTS{'real\svg'},
        },
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_get_settings');
    is($c->result->{login},   'MTR' . $ACCOUNTS{'real\svg'}, 'result->{login}');
    is($c->result->{balance}, $DETAILS{balance},             'result->{balance}');
    is($c->result->{country}, "mt",                          'result->{country}');

    $params->{args}{login} = "MTwrong";
    $c->call_ok($method, $params)->has_error('error for mt5_get_settings wrong login')
        ->error_code_is('PermissionDenied', 'error code for mt5_get_settings wrong login');
};

subtest 'login list' => sub {
    my $method = 'mt5_login_list';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {},
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_login_list');

    my @accounts = map { $_->{login} } @{$c->result};
    cmp_bag(\@accounts, ['MTR' . $ACCOUNTS{'real\svg'}], "mt5_login_list result");
};

subtest 'login list partly successfull result' => sub {
    my $bom_user_mock = Test::MockModule->new('BOM::User');
    $bom_user_mock->mock('mt5_logins', sub { return qw(MTR00000013 MTR00000014) });

    my $mt5_acc_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $mt5_acc_mock->mock(
        'mt5_get_settings',
        sub {
            my $login = shift->{args}{login};

            #result one login should have error msg
            return BOM::RPC::v3::MT5::Account::create_error_future('General') if $login eq 'MTR00000014';

            return Future->done({some => 'valid data'});
        });

    my $method = 'mt5_login_list';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {},
    };

    $c->call_ok($method, $params)->has_error('has error for mt5_login_list')->error_code_is('General', 'Should return correct error code');
};

subtest 'login list without success results' => sub {
    my $bom_user_mock = Test::MockModule->new('BOM::User');
    $bom_user_mock->mock('mt5_logins', sub { return qw(MTR00000013 MTR00000014) });

    my $mt5_acc_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $mt5_acc_mock->mock(
        'mt5_get_settings',
        sub {
            BOM::RPC::v3::MT5::Account::create_error_future('General');
        });

    my $method = 'mt5_login_list';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {},
    };

    $c->call_ok($method, $params)->has_error('has error for mt5_login_list')->error_code_is('General', 'Should return correct error code');
};

subtest 'create new account fails, when we get error during getting login list' => sub {
    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type   => 'gaming',
            country        => 'mt',
            email          => $DETAILS{email},
            name           => $DETAILS{name},
            investPassword => 'Abcd1234',
            mainPassword   => $DETAILS{password}{main},
            leverage       => 100,
        },
    };

    my $bom_user_mock = Test::MockModule->new('BOM::User');
    $bom_user_mock->mock('mt5_logins', sub { return qw(MTR00000013 MTR00000014) });

    my $mt5_acc_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $mt5_acc_mock->mock(
        'mt5_get_settings',
        sub {
            BOM::RPC::v3::MT5::Account::create_error_future('General');
        });

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    $c->call_ok($method, $params)->has_error('has error for mt5_login_list')->error_code_is('General', 'Should return correct error code');
};

subtest 'password check' => sub {
    my $method = 'mt5_password_check';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login    => 'MTR' . $ACCOUNTS{'real\svg'},
            password => $DETAILS{password}{main},
            type     => 'main',
        },
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_password_check');

    $params->{args}{password} = "wrong";
    $c->call_ok($method, $params)->has_error('error for mt5_password_check wrong password')
        ->error_message_like(qr/Forgot your password/, 'error code for mt5_password_check wrong password');

    $params->{args}{login} = "MTwrong";
    $c->call_ok($method, $params)->has_error('error for mt5_password_check wrong login')
        ->error_code_is('PermissionDenied', 'error code for mt5_password_check wrong login');
};

subtest 'password change' => sub {
    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    my $method = 'mt5_password_change';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login         => 'MTR' . $ACCOUNTS{'real\svg'},
            old_password  => $DETAILS{password}{main},
            new_password  => 'Ijkl6789',
            password_type => 'main'
        },
    };
    $params->{args}{login} = "MTwrong";
    $c->call_ok($method, $params)->has_error('error for mt5_password_change wrong login')
        ->error_code_is('PermissionDenied', 'error code for mt5_password_change wrong login');

    is $emitted{"mt5_password_changed"}, undef, "mt5 password change event should not be emitted";

    $params->{args}{login} = 'MTR' . $ACCOUNTS{'real\svg'};

    $c->call_ok($method, $params)->has_no_error('no error for mt5_password_change');
    # This call yields a truth integer directly, not a hash
    is($c->result, 1, 'result');

    ok $emitted{"mt5_password_changed"}, "mt5 password change event emitted";

    # reset throller, test for password limit
    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    $params->{args}->{login}        = 'MTR' . $ACCOUNTS{'real\svg'};
    $params->{args}->{old_password} = $DETAILS{password}{main};
    $params->{args}->{new_password} = 'Ijkl6789';
    $c->call_ok($method, $params)->has_no_error('no error for mt5_password_change');
    is($c->result, 1, 'result');

    $c->call_ok($method, $params)->has_error('error for mt5_password_change wrong login');
    is(
        $c->result->{error}->{message_to_client},
        'It looks like you have already made the request. Please try again later.',
        'change password hits rate limit'
    );
    # reset throller, test for password limit
    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    $params->{args}->{new_password} = '12345678';

    $c->call_ok($method, $params)->has_no_system_error->has_error('error for mt5_password_change invalid password')
        ->error_code_is('IncorrectMT5PasswordFormat', 'error code is IncorrectMT5PasswordFormat')
        ->error_message_like(qr/Your password must have/, 'error message is correct');
    is(BOM::RPC::v3::Utility::_validate_mt5_password({password => '12345678bc'}),   '', 'validated correct password with atleast two combinations');
    is(BOM::RPC::v3::Utility::_validate_mt5_password({password => '@12345678BCc'}), '', 'validated correct password with special characters');
    is(BOM::RPC::v3::Utility::_validate_mt5_password({password => 'waterloo'}),     1,  'only alphabets',);
    is(BOM::RPC::v3::Utility::_validate_mt5_password({password => '@@@###!!!'}),    1,  'only special characters',);
    is(
        BOM::RPC::v3::Utility::_validate_mt5_password({
                password => 'jkl6789Ijkl6789Ijkl678l673',
            }
        ),
        1,
        'too long.',
    );
    is(
        BOM::RPC::v3::Utility::_validate_mt5_password({
                password => 'pa$5A',
            }
        ),
        1,
        'too short.',
    );
};

subtest 'password reset' => sub {
    my $method = 'mt5_password_reset';
    mailbox_clear();

    my $code = BOM::Platform::Token->new({
            email       => $DETAILS{email},
            expires_in  => 3600,
            created_for => 'mt5_password_reset'
        })->token;

    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login             => 'MTR' . $ACCOUNTS{'real\svg'},
            new_password      => 'Ijkl6789',
            password_type     => 'main',
            verification_code => $code
        }};

    $c->call_ok($method, $params)->has_no_error('no error for mt5_password_change');
    # This call yields a truth integer directly, not a hash
    is($c->result, 1, 'result');

    my $subject = 'Your MT5 password has been reset.';
    my $msg     = mailbox_search(
        email   => $DETAILS{email},
        subject => qr/\Q$subject\E/
    );
    ok($msg, "email received");
    $code = BOM::Platform::Token->new({
            email       => $DETAILS{email},
            expires_in  => 3600,
            created_for => 'mt5_password_reset'
        })->token;
    $params->{args}->{verification_code} = $code;
    $params->{args}->{new_password}      = '12345678';

    $c->call_ok($method, $params)->has_no_system_error->has_error('error for mt5_password_reset invalid password')
        ->error_code_is('IncorrectMT5PasswordFormat', 'error code is IncorrectMT5PasswordFormat')->error_message_is(
        'Your password must have a minimum of 8 characters. It must also have at least 2 out of the following 3 types of characters: uppercase letters, lowercase letters, and numbers.',
        'error message is correct'
        );

};

subtest 'investor password reset' => sub {
    my $method = 'mt5_password_reset';
    mailbox_clear();

    my $demo_account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $demo_account_mock->mock('_fetch_mt5_lc', sub { return LandingCompany::Registry::get('svg'); });

    my $code = BOM::Platform::Token->new({
            email       => $DETAILS{email},
            expires_in  => 3600,
            created_for => 'mt5_password_reset'
        })->token;

    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login             => 'MTR' . $ACCOUNTS{'real\svg'},
            new_password      => 'Abcd1234',
            password_type     => 'investor',
            verification_code => $code
        }};

    $c->call_ok($method, $params)->has_no_error('no error for mt5_password_change');
    # This call yields a truth integer directly, not a hash
    is($c->result, 1, 'result');

    my $subject = 'Your MT5 password has been reset.';
    my $msg     = mailbox_search(
        email   => $DETAILS{email},
        subject => qr/\Q$subject\E/
    );
    ok($msg, "email received");

    $demo_account_mock->unmock;
};

subtest 'password check investor' => sub {
    my $method = 'mt5_password_check';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login         => 'MTR' . $ACCOUNTS{'real\svg'},
            password      => 'Abcd1234',
            password_type => 'investor'
        },
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_password_check');
};

done_testing();
