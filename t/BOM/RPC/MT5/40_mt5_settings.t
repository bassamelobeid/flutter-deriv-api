use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::Mojo;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::RPC::QueueClient;
use BOM::Test::Helper::Client qw(create_client top_up);
use BOM::Test::Email qw(:no_event);

use LandingCompany::Registry;
use BOM::MT5::User::Async;
use BOM::Platform::Token;
use BOM::User;
use Test::BOM::RPC::Accounts;
use Email::Valid;

my $c = BOM::Test::RPC::QueueClient->new();

@BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

my %ACCOUNTS                    = %Test::BOM::RPC::Accounts::MT5_ACCOUNTS;
my %DETAILS                     = %Test::BOM::RPC::Accounts::ACCOUNT_DETAILS;
my %GROUP_MAPPINGS              = %Test::BOM::RPC::Accounts::MT5_GROUP_MAPPING;
my %EXPECTED_MT5_GROUP_MAPPINGS = %Test::BOM::RPC::Accounts::EXPECTED_MT5_GROUP_MAPPINGS;

my %emitted;
my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->mock(
    'emit',
    sub {
        my ($type, $data) = @_;
        $emitted{$type}++;
    });

# send_email sub is imported into Account module, remarkable for reset password tests
my $email_data;
my $mocker_account = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
$mocker_account->mock(
    'send_email',
    sub {
        $email_data = shift;
        $mocker_account->original('send_email')->($email_data);
    });

# Setup a test user
my $test_client = create_client('CR');
$test_client->email($DETAILS{email});
$test_client->set_default_account('USD');
$test_client->binary_user_id(1);

$test_client->set_authentication('ID_DOCUMENT', {status => 'pass'});
$test_client->save;

my $user = BOM::User->create(
    email    => $DETAILS{email},
    password => 's3kr1t',
);
$user->add_client($test_client);

my $m     = BOM::Platform::Token::API->new;
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
BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts03->all(0);
my $r = $c->call_ok('mt5_new_account', $params)->has_no_error('no error for mt5_new_account')->result;

subtest 'get settings' => sub {
    my $method = 'mt5_get_settings';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login => 'MTR' . $ACCOUNTS{'real\p01_ts03\synthetic\svg_std_usd\01'},
        },
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_get_settings');

    is($c->result->{login},   'MTR' . $ACCOUNTS{'real\p01_ts03\synthetic\svg_std_usd\01'}, 'result->{login}');
    is($c->result->{balance}, $DETAILS{balance},                                           'result->{balance}');
    is($c->result->{country}, "mt",                                                        'result->{country}');

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
    is($c->result->[0]->{landing_company_short}, 'svg',       "landing_company_short result");
    is($c->result->[0]->{market_type},           'synthetic', "market_type result");
    is($c->result->[0]->{sub_account_type},      'financial', "sub_account_type result");
    is($c->result->[0]->{account_type},          'real',      "account_type result");
    cmp_bag(\@accounts, ['MTR' . $ACCOUNTS{'real\p01_ts03\synthetic\svg_std_usd\01'}], "mt5_login_list result");
};

subtest 'login list partly successfull result' => sub {
    my $bom_user_mock = Test::MockModule->new('BOM::User');
    $bom_user_mock->mock('get_mt5_loginids', sub { return qw(MTR40000001 MTR00001014) });

    my $mt5_acc_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $mt5_acc_mock->mock(
        'mt5_get_settings',
        sub {
            my $login = shift->{args}{login};

            #result one login should have error msg
            return BOM::RPC::v3::MT5::Account::create_error_future('General') if $login eq 'MTR00001014';

            return Future->done({some => 'valid data'});
        });

    my $method = 'mt5_login_list';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {},
    };

    $c->call_ok($method, $params)->has_error('has error for mt5_login_list')->error_code_is('General', 'Should return correct error code');
    $mt5_acc_mock->unmock('mt5_get_settings');
};

subtest 'login list with MT5 connection problem ' => sub {
    my $bom_user_mock = Test::MockModule->new('BOM::User');
    $bom_user_mock->mock('get_mt5_loginids', sub { return qw(MTR41000001 MTR00001014) });

    my $mt5_async_mock = Test::MockModule->new('BOM::MT5::User::Async');
    $mt5_async_mock->mock(
        'get_user',
        sub {
            return Future->fail({
                code  => 'NoConnection',
                error => '',
            });
        });

    my $method = 'mt5_login_list';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {},
    };

    $c->call_ok($method, $params)->has_error('has error for mt5_login_list')->error_code_is('NoConnection', 'Should return correct error code');
    $mt5_async_mock->unmock('get_user');
};

subtest 'login list with archived login id ' => sub {
    my $bom_user_mock = Test::MockModule->new('BOM::User');
    $bom_user_mock->mock('get_mt5_loginids', sub { return qw(MTR41000001 MTR00001014) });

    my $mt5_acc_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $mt5_acc_mock->mock('_check_logins', sub { return 1; });

    my $mt5_async_mock = Test::MockModule->new('BOM::MT5::User::Async');
    $mt5_async_mock->mock(
        'get_user',
        sub {
            my $login = shift;

            return Future->fail({
                    code  => 'NotFound',
                    error => 'Not found',
                }) if $login eq 'MTR00001014';

            return $mt5_async_mock->original('get_user')->($login);
        });

    my $method = 'mt5_login_list';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {},
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_login_list');

    my @accounts = map { $_->{login} } @{$c->result};
    cmp_bag(\@accounts, ['MTR' . $ACCOUNTS{'real\p01_ts03\synthetic\svg_std_usd\01'}], "mt5_login_list result");
    $mt5_async_mock->unmock('get_user');
    $mt5_acc_mock->unmock('_check_logins');
};

subtest 'login list without success results' => sub {
    my $bom_user_mock = Test::MockModule->new('BOM::User');
    $bom_user_mock->mock('get_mt5_loginids', sub { return qw(MTR40000001 MTR00001014) });

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
    $mt5_acc_mock->unmock('mt5_get_settings');
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
    $bom_user_mock->mock('mt5_logins', sub { return qw(MTR40000001 MTR00001014) });

    my $mt5_acc_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $mt5_acc_mock->mock(
        'mt5_get_settings',
        sub {
            BOM::RPC::v3::MT5::Account::create_error_future('General');
        });

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    $c->call_ok($method, $params)->has_error('has error for mt5_login_list')->error_code_is('General', 'Should return correct error code');
    $mt5_acc_mock->unmock('mt5_get_settings');
};

subtest 'password check' => sub {
    my $method = 'mt5_password_check';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login    => 'MTR' . $ACCOUNTS{'real\p01_ts03\synthetic\svg_std_usd\01'},
            password => $DETAILS{password}{main},
            type     => 'main',
        },
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_password_check');

    $params->{args}{password} = "wrong";
    $c->call_ok($method, $params)->has_error('error for mt5_password_check wrong password')
        ->error_code_is('InvalidPassword', 'error code for mt5_password_check wrong password');

    $params->{args}{login} = "MTwrong";
    $c->call_ok($method, $params)->has_error('error for mt5_password_check wrong login')
        ->error_code_is('PermissionDenied', 'error code for mt5_password_check wrong login');
};

subtest 'MT5 old and new group names mapping' => sub {

    my @groups = keys %EXPECTED_MT5_GROUP_MAPPINGS;

    foreach (@groups) {
        my $landing_company_short = $EXPECTED_MT5_GROUP_MAPPINGS{$_}{landing_company_short};
        my $market_type           = $EXPECTED_MT5_GROUP_MAPPINGS{$_}{market_type};
        my $sub_account_type      = $EXPECTED_MT5_GROUP_MAPPINGS{$_}{sub_account_type};
        my $account_type          = $EXPECTED_MT5_GROUP_MAPPINGS{$_}{account_type};
        my $config                = BOM::RPC::v3::MT5::Account::get_mt5_account_type_config($_);
        is($landing_company_short, $config->{landing_company_short}, "Comparing landing_company_short for $_");
        is($market_type,           $config->{market_type},           "Comparing market_type for $_");
        is($sub_account_type,      $config->{sub_account_type},      "Comparing sub_account_type for $_");
        is($account_type,          $config->{account_type},          "Comparing account_type for $_");
    }
};

subtest 'mt5 settings with correct account type' => sub {

    my @keys = keys %GROUP_MAPPINGS;

    my $mock_mt5_group = Test::MockModule->new('BOM::RPC::v3::MT5::Account');

    my $v = 1;
    foreach my $mt5_group (@keys) {
        my $email       = $v . $DETAILS{email};
        my $test_client = create_client('CR');
        $test_client->email($email);
        $test_client->set_default_account('USD');
        $test_client->binary_user_id($v);
        $test_client->set_authentication('ID_DOCUMENT', {status => 'pass'});
        $test_client->save;
        my $user = BOM::User->create(
            email    => $email,
            password => 's3kr1t'
        );

        $user->add_client($test_client);

        my $m     = BOM::Platform::Token::API->new;
        my $token = $m->create_token($test_client->loginid, 'test token');

        $mock_mt5_group->mock('_mt5_group', sub { return $mt5_group });

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
        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        my $res = $c->call_ok('mt5_new_account', $params)->has_no_error->result;

        my $bom_user_mock = Test::MockModule->new('BOM::User');
        $bom_user_mock->mock('mt5_logins', sub { return 'MTR' . $ACCOUNTS{$_} });

        my $method  = 'mt5_get_settings';
        my $params2 = {
            language => 'EN',
            token    => $token,
            args     => {
                login => 'MTR' . $ACCOUNTS{$mt5_group},
            },
        };

        $c->call_ok($method, $params2)->has_no_error('no error for mt5_get_settings');
        is($c->result->{landing_company_short}, $GROUP_MAPPINGS{$mt5_group}{landing_company_short}, 'landing_company_short for ' . $mt5_group);
        is($c->result->{market_type},           $GROUP_MAPPINGS{$mt5_group}{market_type},           'market_type for ' . $mt5_group);
        is($c->result->{sub_account_type},      $GROUP_MAPPINGS{$mt5_group}{sub_account_type},      'sub_account_type for ' . $mt5_group);
        is($c->result->{account_type},          $GROUP_MAPPINGS{$mt5_group}{account_type},          'account_type for ' . $mt5_group);

        $v = $v + 2;
    }
};

# Tests for MT5 inactive aclient
my $inactive_client = create_client('CR');
$inactive_client->email("Inactive" . $DETAILS{email});
$inactive_client->set_default_account('USD');
$inactive_client->binary_user_id(3);
$inactive_client->set_authentication('ID_DOCUMENT', {status => 'pass'});
$inactive_client->save;

my $inactive_user = BOM::User->create(
    email    => "Inactive" . $DETAILS{email},
    password => 's3kr1t',
);
$inactive_user->add_client($inactive_client);
$m     = BOM::Platform::Token::API->new;
$token = $m->create_token($inactive_client->loginid, 'test token');

$params = {
    language => 'EN',
    token    => $token,
    args     => {
        account_type => 'gaming',
        country      => 'mt',
        email        => "Inactive" . $DETAILS{email},
        name         => $DETAILS{name},
        mainPassword => $DETAILS{password}{main},
        leverage     => 100,
    },
};

# Throttle function limits requests to 1 per minute which may cause
# consecutive tests to fail without a reset.
BOM::RPC::v3::MT5::Account::reset_throttler($inactive_client->loginid);

#  Mock inactive MT5 account
my $mocker_inactive_account = Test::MockModule->new('BOM::MT5::User::Async');
$mocker_inactive_account->mock(
    'create_user',
    sub {
        return Future->done({login => 'MTR' . $ACCOUNTS{'real\p01_ts01\inactive_accounts_financial'}});
    });

$c->call_ok('mt5_new_account', $params)->has_no_error('no error for mt5_new_account');

subtest 'get settings' => sub {

    my $method = 'mt5_get_settings';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login => 'MTR' . $ACCOUNTS{'real\p01_ts01\inactive_accounts_financial'},
        },
    };

    $c->call_ok($method, $params)->has_error('error for mt5_get_settings inactive account')
        ->error_code_is('MT5AccountInactive', 'error code for mt5_get_settings inactive account');
};

subtest 'login list for inactive account' => sub {
    my $method = 'mt5_login_list';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {},
    };

    BOM::RPC::v3::MT5::Account::reset_throttler($ACCOUNTS{'real\p01_ts01\inactive_accounts_financial'});

    $c->call_ok($method, $params)->has_no_error('no error for mt5_login_list');

    my @accounts = map { $_->{login} } @{$c->result};

    is(scalar(@accounts), 0, "empty login_list for inactive MT5 account");

};

$mocker_inactive_account->unmock('create_user');

done_testing();
