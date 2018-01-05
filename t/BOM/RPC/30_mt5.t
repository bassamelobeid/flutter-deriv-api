use strict;
use warnings;

use Test::Most;
use Test::Mojo;

use BOM::Test::RPC::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Helper::Client qw(create_client top_up);
use BOM::Platform::User;
use BOM::MT5::User::Async;

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);

# Mocked account details
# This hash shared between two files, and should be kept in-sync to avoid test failures
#   t/BOM/RPC/30_mt5.t
#   t/lib/mock_binary_mt5.pl
my %DETAILS = (
    login    => '__MOCK__',
    password => 'Efgh4567',
    email    => 'test.account@binary.com',
    name     => 'Test',
    group    => 'real\something',
    country  => 'Malta',
    balance  => '1234.56',
);

# Setup a test user
my $test_client = create_client('MF');    # broker_code = MF to ensure ID_DOCUMENT passes
$test_client->email($DETAILS{email});
$test_client->save;

my $user = BOM::Platform::User->create(
    email    => $DETAILS{email},
    password => 's3kr1t',
);
$user->save;
$user->add_loginid({loginid => $test_client->loginid});
$user->add_loginid({loginid => 'MT' . $DETAILS{login}});
$user->save;

my $m = BOM::Database::Model::AccessToken->new;
my $token = $m->create_token($test_client->loginid, 'test token');

@BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

# Throttle function limits requests to 1 per minute which may cause
# consecutive tests to fail without a reset.
BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

subtest 'new account' => sub {
    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type   => 'demo',
            country        => 'mt',
            email          => $DETAILS{email},
            name           => $DETAILS{name},
            investPassword => 'Abcd1234',
            mainPassword   => $DETAILS{password},
            leverage       => 100,
        },
    };
    $c->call_ok($method, $params)
        ->has_no_error('no error for mt5_new_account');
    is($c->result->{login}, $DETAILS{login}, 'result->{login}');
};

subtest 'get settings' => sub {
    my $method = 'mt5_get_settings';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login => $DETAILS{login},
        },
    };
    $c->call_ok($method, $params)
        ->has_no_error('no error for mt5_get_settings');
    is($c->result->{login},   $DETAILS{login},   'result->{login}');
    is($c->result->{balance}, $DETAILS{balance}, 'result->{balance}');
    is($c->result->{country}, "mt",              'result->{country}');

    $params->{args}{login} = "MTwrong";
    $c->call_ok($method, $params)
        ->has_error('error for mt5_get_settings wrong login')
        ->error_code_is('PermissionDenied', 'error code for mt5_get_settings wrong login');
};

subtest 'set settings' => sub {
    my $method = 'mt5_set_settings';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login   => $DETAILS{login},
            name    => "Test2",
            country => 'mt',
        },
    };
    $c->call_ok($method, $params)
        ->has_no_error('no error for mt5_set_settings');
    is($c->result->{login},   $DETAILS{login}, 'result->{login}');
    is($c->result->{name},    "Test2", 'result->{name}');
    is($c->result->{country}, "mt",    'result->{country}');

    $params->{args}{login} = "MTwrong";
    $c->call_ok($method, $params)
        ->has_error('error for mt5_set_settings wrong login')
        ->error_code_is('PermissionDenied', 'error code for mt5_set_settings wrong login');
};

subtest 'password check' => sub {
    my $method = 'mt5_password_check';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login    => $DETAILS{login},
            password => $DETAILS{password},
        },
    };
    $c->call_ok($method, $params)
        ->has_no_error('no error for mt5_password_check');

    $params->{args}{login} = "MTwrong";
    $c->call_ok($method, $params)
        ->has_error('error for mt5_password_check wrong login')
        ->error_code_is('PermissionDenied', 'error code for mt5_password_check wrong login');
};

subtest 'password change' => sub {
    my $method = 'mt5_password_change';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login        => $DETAILS{login},
            old_password => $DETAILS{password},
            new_password => 'Ijkl6789',
        },
    };
    $c->call_ok($method, $params)
        ->has_no_error('no error for mt5_password_change');
    # This call yields a truth integer directly, not a hash
    is($c->result, 1, 'result');

    $params->{args}{login} = "MTwrong";
    $c->call_ok($method, $params)
        ->has_error('error for mt5_password_change wrong login')
        ->error_code_is('PermissionDenied', 'error code for mt5_password_change wrong login');
};

subtest 'deposit' => sub {
    # User needs some real money now
    top_up $test_client, USD => 1000;

    my $method = "mt5_deposit";
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            from_binary => $test_client->loginid,
            to_mt5      => "__MOCK__",
            amount      => 150,
        },
    };
    $c->call_ok($method, $params)
        ->has_no_error('no error for mt5_deposit');
    ok(defined $c->result->{binary_transaction_id}, 'result has a transaction ID');

    # TODO(leonerd): assert that account balance is now 1000-150 = 850

    $params->{args}{to_mt5} = "MTwrong";
    $c->call_ok($method, $params)
        ->has_error('error for mt5_deposit wrong login')
        ->error_code_is('PermissionDenied', 'error code for mt5_deposit wrong login');
};

subtest 'withdrawal' => sub {
    # TODO(leonerd): assertions in here about balance amounts would be
    #   sensitive to results of the previous test of mt5_deposit.
    my $method = "mt5_withdrawal";
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            from_mt5  => "__MOCK__",
            to_binary => $test_client->loginid,
            amount    => 150,
        },
    };
    $c->call_ok($method, $params)
        ->has_no_error('no error for mt5_withdrawal');
    ok(defined $c->result->{binary_transaction_id}, 'result has a transaction ID');

    $params->{args}{from_mt5} = "MTwrong";
    $c->call_ok($method, $params)
        ->has_error('error for mt5_withdrawal wrong login')
        ->error_code_is('PermissionDenied', 'error code for mt5_withdrawal wrong login');
};

done_testing();
