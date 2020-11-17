use strict;
use warnings;
use Guard;
use Test::More;
use Test::Mojo;
use Test::MockModule;
use Test::MockTime qw(:all);
use JSON::MaybeUTF8;

use LandingCompany::Registry;
use BOM::Test::RPC::QueueClient;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Helper::Client qw(create_client top_up);
use BOM::MT5::User::Async;
use BOM::Platform::Token;
use BOM::User;
use BOM::Config::Runtime;

use Test::BOM::RPC::Accounts;

my $c = BOM::Test::RPC::QueueClient->new();
BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->MT5(999);

my $runtime_system  = BOM::Config::Runtime->instance->app_config->system;
my $runtime_payment = BOM::Config::Runtime->instance->app_config->payments;

# unlimit daily transfer
$runtime_payment->transfer_between_accounts->limits->MT5(999);

scope_guard { restore_time() };

my $manager_module = Test::MockModule->new('BOM::MT5::User::Async');
$manager_module->mock(
    'deposit',
    sub {
        return Future->done({success => 1});
    });

$manager_module->mock(
    'withdrawal',
    sub {
        return Future->done({success => 1});
    });

@BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

my %ACCOUNTS       = %Test::BOM::RPC::Accounts::MT5_ACCOUNTS;
my %DETAILS        = %Test::BOM::RPC::Accounts::ACCOUNT_DETAILS;
my %financial_data = %Test::BOM::RPC::Accounts::FINANCIAL_DATA;

# Setup a test user
my $test_client = create_client('CR');
$test_client->email($DETAILS{email});
$test_client->set_default_account('USD');
$test_client->binary_user_id(1);
$test_client->tax_residence('mt');
$test_client->tax_identification_number('111222333');
$test_client->set_authentication('ID_DOCUMENT', {status => 'pass'});
$test_client->account_opening_reason('nothing');
$test_client->save;
my $test_client_vr = create_client('VRTC');
$test_client_vr->email($DETAILS{email});
$test_client_vr->set_default_account('USD');
$test_client_vr->save;

my $user = BOM::User->create(
    email    => $DETAILS{email},
    password => 's3kr1t',
);
$user->add_client($test_client);
$user->add_client($test_client_vr);

my $m        = BOM::Platform::Token::API->new;
my $token    = $m->create_token($test_client->loginid, 'test token');
my $token_vr = $m->create_token($test_client_vr->loginid, 'test token');

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

sub _get_mt5transfer_from_transaction {
    my ($dbic, $transaction_id) = @_;

    my $result = $dbic->run(
        fixup => sub {
            $_->selectrow_hashref(
                "Select mt.* FROM payment.mt5_transfer mt JOIN transaction.transaction tt
                ON mt.payment_id = tt.payment_id where tt.id = ?",
                undef,
                $transaction_id,
            );
        });
    return $result;
}

subtest 'deposit' => sub {
    # User needs some real money now
    top_up $test_client, USD => 1000;

    my $loginid = $test_client->loginid;

    my $method = "mt5_deposit";
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            from_binary => $loginid,
            to_mt5      => 'MTR' . $ACCOUNTS{'real\svg'},
            amount      => 180,
        },
    };

    set_absolute_time(Date::Utility->new('2018-02-15')->epoch);

    my $demo_account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $demo_account_mock->mock('_fetch_mt5_lc', sub { return LandingCompany::Registry::get('svg'); });

    BOM::RPC::v3::MT5::Account::reset_throttler($loginid);
    $c->call_ok($method, $params)->has_no_error('no error for mt5_deposit');
    ok(defined $c->result->{binary_transaction_id}, 'result has a transaction ID');
    subtest record_mt5_transfer_deposit => sub {
        my $mt5_transfer = _get_mt5transfer_from_transaction($test_client->db->dbic, $c->result->{binary_transaction_id});
        is($mt5_transfer->{mt5_amount}, -180, 'Correct amount recorded');
    };
    # assert that account balance is now 1000-180 = 820
    cmp_ok $test_client->default_account->balance, '==', 820, "Correct balance after deposited to mt5 account";

    BOM::RPC::v3::MT5::Account::reset_throttler($loginid);

    BOM::RPC::v3::MT5::Account::reset_throttler($loginid);

    $runtime_system->suspend->experimental_currencies(['USD']);
    $c->call_ok($method, $params)->has_error('error as currency is experimental')->error_code_is('Experimental', 'error code is Experimental')
        ->error_message_is('This currency is temporarily suspended. Please select another currency to proceed.');
    $runtime_system->suspend->experimental_currencies([]);

    BOM::RPC::v3::MT5::Account::reset_throttler($loginid);

    $test_client->status->set('no_withdrawal_or_trading', 'system', 'pending investigations');
    $c->call_ok($method, $params)->has_error('client is blocked from withdrawal')->error_code_is('MT5DepositError', 'error code is MT5DepositError')
        ->error_message_is('You cannot perform this action, as your account is withdrawal locked.');
    $test_client->status->clear_no_withdrawal_or_trading;

    BOM::RPC::v3::MT5::Account::reset_throttler($loginid);
    $params->{args}{to_mt5} = "MTwrong";
    $c->call_ok($method, $params)->has_error('error for mt5_deposit wrong login')
        ->error_code_is('PermissionDenied', 'error code for mt5_deposit wrong login');

    BOM::RPC::v3::MT5::Account::reset_throttler($loginid);

    $test_client->status->set('mt5_withdrawal_locked', 'system', 'testing');
    $params->{args}{to_mt5} = 'MTR' . $ACCOUNTS{'real\svg'};
    $c->call_ok($method, $params)->has_error('client is blocked from withdrawal')->error_code_is('MT5DepositError', 'error code is MT5DepositError')
        ->error_message_is('You cannot perform this action, as your account is withdrawal locked.');
    $test_client->status->clear_mt5_withdrawal_locked;

    $demo_account_mock->unmock;

};

subtest 'demo account can not be tagged as an agent' => sub {
    my $method            = 'mt5_new_account';
    my $demo_account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $demo_account_mock->mock('_get_mt5_account_from_affiliate_token', sub { return '1234' });
    $test_client->myaffiliates_token("asdfas");
    $test_client->save;

    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type     => 'demo',
            mt5_account_type => 'financial',
            country          => 'af',
            email            => $DETAILS{email},
            name             => $DETAILS{name},
            investPassword   => 'Abcd1234',
            mainPassword     => $DETAILS{password}{main},
        },
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_new_account');
    is($c->result->{agent}, undef, 'Agent should not be tagged for demo account');
    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    $test_client->myaffiliates_token("");
    $test_client->save;
};

subtest 'virtual_deposit' => sub {

    my $method = "mt5_new_account";
    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    my $new_account_params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type     => 'demo',
            mt5_account_type => 'financial_stp',
            country          => 'af',
            email            => $DETAILS{email},
            name             => $DETAILS{name},
            investPassword   => 'Abcd1234',
            mainPassword     => $DETAILS{password}{main},
        },
    };

    $c->call_ok($method, $new_account_params)->has_no_error('no error for mt5_new_account');
    is($c->result->{balance},         10000,      'Balance is 10,000 upon creation');
    is($c->result->{display_balance}, '10000.00', 'Display balance is "10000.00" upon creation');

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    my $demo_account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $demo_account_mock->mock('_is_account_demo', sub { return 1 });
    $demo_account_mock->mock('_fetch_mt5_lc',    sub { return LandingCompany::Registry::get('iom'); });

    $method = "mt5_deposit";
    my $deposit_demo_params = {
        language => 'EN',
        token    => $token,
        args     => {
            to_mt5 => 'MTR' . $ACCOUNTS{'real\svg'},
            amount => 180,
        },
    };

    $c->call_ok($method, $deposit_demo_params)->has_error('Cannot Deposit')->error_code_is('MT5DepositError')
        ->error_message_like(qr/balance falls below 1000.00 USD/, 'Balance is higher');

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    subtest 'virtual deposit under mt5 withdrawal locked' => sub {
        my $config_mock = Test::MockModule->new('BOM::Config');
        my $status_mock = Test::MockModule->new('BOM::User::Client::Status');

        $status_mock->mock(
            'mt5_withdrawal_locked',
            sub {
                return 1;
            });

        # With this one we can hopefully pass the 1000 USD validation.
        $config_mock->mock(
            'payment_agent',
            sub {
                return {
                    minimum_topup_balance => {
                        DEFAULT => 10000000,
                    },
                };
            });

        $c->call_ok($method, $deposit_demo_params)->has_no_error('Can top up demo account');
        $config_mock->unmock_all;
        $status_mock->unmock_all;
    };

    $demo_account_mock->unmock;

};

subtest 'mx_deposit' => sub {
    my $test_mx_client = create_client('MX');
    $test_mx_client->account('USD');
    $test_mx_client->email($DETAILS{email});
    $test_mx_client->save();

    $user->add_client($test_mx_client);

    my $token_mx = $m->create_token($test_mx_client->loginid, 'test token');

    my $params_mx = {
        language => 'EN',
        token    => $token_mx,
        args     => {
            from_binary => $test_mx_client->loginid,
            to_mt5      => 'MTR' . $ACCOUNTS{'real\svg'},
            amount      => 180,
        },
    };

    my $demo_account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $demo_account_mock->mock('_fetch_mt5_lc', sub { return LandingCompany::Registry::get('maltainvest'); });

    my $method = "mt5_deposit";

    BOM::RPC::v3::MT5::Account::reset_throttler($test_mx_client->loginid);

    $c->call_ok($method, $params_mx)->has_error('Cannot access MT5 as MX')
        ->error_code_is('MT5DepositError', 'Transfers to MT5 not allowed error_code')->error_message_like(qr/not allow MT5 trading/);
    $demo_account_mock->unmock;
};

subtest 'mx_withdrawal' => sub {
    my $test_mx_client = create_client('MX');
    $test_mx_client->account('USD');
    $test_mx_client->email($DETAILS{email});
    $test_mx_client->save();

    $user->add_client($test_mx_client);

    my $token_mx = $m->create_token($test_mx_client->loginid, 'test token');

    my $params_mx = {
        language => 'EN',
        token    => $token_mx,
        args     => {
            from_mt5  => 'MTR' . $ACCOUNTS{'real\svg'},
            to_binary => $test_mx_client->loginid,
            amount    => 350,
        },
    };

    my $method = "mt5_withdrawal";

    my $demo_account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $demo_account_mock->mock('_fetch_mt5_lc', sub { return LandingCompany::Registry::get('maltainvest'); });

    BOM::RPC::v3::MT5::Account::reset_throttler($test_mx_client->loginid);

    $c->call_ok($method, $params_mx)->has_error('Cannot access MT5 as MX')->error_code_is('MT5WithdrawalError', 'error code is MT5WithdrawalError')
        ->error_message_like(qr/not allow MT5 trading/);
    $demo_account_mock->unmock;
};

subtest 'withdrawal' => sub {
    # TODO(leonerd): assertions in here about balance amounts would be
    #   sensitive to results of the previous test of mt5_deposit.
    my $method = "mt5_withdrawal";
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            from_mt5  => 'MTR' . $ACCOUNTS{'real\svg'},
            to_binary => $test_client_vr->loginid,
            amount    => 150,
        },
    };

    set_absolute_time(Date::Utility->new('2018-02-15')->epoch);

    my $demo_account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $demo_account_mock->mock('_fetch_mt5_lc', sub { return LandingCompany::Registry::get('svg'); });

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    $c->call_ok($method, $params)->has_error('cannot withdrawals to virtual account')
        ->error_message_is('You cannot perform this action with a virtual account.');

    $params->{args}->{to_binary} = $test_client->loginid;
    $params->{token} = $token_vr;
    $c->call_ok($method, $params)->has_error('fail withdrawals with vr_token')->error_code_is('PermissionDenied', 'error code is PermissionDenied');
    $params->{token} = $token;

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    $c->call_ok($method, $params)->has_no_error('no error for mt5_withdrawal');
    ok(defined $c->result->{binary_transaction_id}, 'result has a transaction ID');

    cmp_ok $test_client->default_account->balance, '==', 820 + 150, "Correct balance after withdrawal";

    subtest record_mt5_transfer_withdrawal => sub {
        my $mt5_transfer = _get_mt5transfer_from_transaction($test_client->db->dbic, $c->result->{binary_transaction_id});

        is($mt5_transfer->{mt5_amount}, 150, 'Correct amount recorded');
    };
    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    $runtime_system->suspend->experimental_currencies(['USD']);
    $c->call_ok($method, $params)->has_error('error as currency is experimental')->error_code_is('Experimental', 'error code is Experimental')
        ->error_message_is('This currency is temporarily suspended. Please select another currency to proceed.');
    $runtime_system->suspend->experimental_currencies([]);

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    $params->{args}{from_mt5} = "MTwrong";
    $c->call_ok($method, $params)->has_error('error for mt5_withdrawal wrong login')
        ->error_code_is('PermissionDenied', 'error code for mt5_withdrawal wrong login');

    $demo_account_mock->unmock;
};

subtest 'labuan withdrawal' => sub {
    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type     => 'financial',
            mt5_account_type => 'financial_stp',
            country          => 'af',
            email            => $DETAILS{email},
            name             => $DETAILS{name},
            investPassword   => 'Abcd1234',
            mainPassword     => $DETAILS{password}{main},
        },
    };

    $c->call_ok($method, $params)->has_no_error('no error for mt5_new_account without investPassword');
    is($c->result->{login},           'MTR' . $ACCOUNTS{'real\labuan_financial_stp'}, 'result->{login}');
    is($c->result->{balance},         0,                                              'Balance is 0 upon creation');
    is($c->result->{display_balance}, '0.00',                                         'Display balance is "0.00" upon creation');

    $test_client->financial_assessment({data => '{}'});
    $test_client->save();

    $method = "mt5_withdrawal";
    $params = {
        language => 'EN',
        token    => $token,
        args     => {
            from_mt5  => 'MTR' . $ACCOUNTS{'real\labuan_financial_stp'},
            to_binary => $test_client->loginid,
            amount    => 50,
        },
    };

    set_absolute_time(Date::Utility->new('2018-02-15')->epoch);

    my $account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $account_mock->mock('_fetch_mt5_lc', sub { return LandingCompany::Registry::get('labuan'); });

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    my $mocked_status = Test::MockModule->new(ref($test_client->status));
    $mocked_status->mock('cashier_locked', sub { return 1 });

    $c->call_ok($method, $params)->has_error('request failed as client with cashier locked status set cannot withdraw')
        ->error_code_is('MT5WithdrawalError', 'error code is MT5WithdrawalError')
        ->error_message_is('Your account cashier is locked. Please contact us for more information.');

    $mocked_status->unmock_all;

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    $c->call_ok($method, $params)->has_error('request failed as labuan needs to have valid documents')
        ->error_code_is('MT5WithdrawalError', 'error code is MT5WithdrawalError')
        ->error_message_is(
        'Your identity documents have passed their expiration date. Kindly send a scan of a valid identity document to support@binary.com.');

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    my $mocked_client = Test::MockModule->new(ref($test_client));
    $mocked_client->mock('has_valid_documents', sub { 1 });

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    $c->call_ok($method, $params)->has_no_error('Withdrawal allowed from labuan mt5 without FA before first deposit');
    cmp_ok $test_client->default_account->balance, '==', 820 + 150 + 50, "Correct balance after withdrawal";

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    $c->call_ok(
        'mt5_deposit',
        {
            language => 'EN',
            token    => $token,
            args     => {
                to_mt5      => 'MTR' . $ACCOUNTS{'real\labuan_financial_stp'},
                from_binary => $test_client->loginid,
                amount      => 50,
            },
        })->has_no_error('Deposit allowed to labuan mt5 account without FA');
    cmp_ok $test_client->default_account->balance, '==', 820 + 150, "Correct balance after deposit";

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    $c->call_ok($method, $params)->has_error('Withdrawal request failed.')->error_code_is('MT5WithdrawalError', 'error code is MT5WithdrawalError')
        ->error_message_like(qr/complete your financial assessment/);

    $account_mock->mock('_fetch_mt5_lc', sub { return LandingCompany::Registry::get('svg'); });
    $params->{args}->{from_mt5} = 'MTR' . $ACCOUNTS{'real\svg'};
    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    $c->call_ok($method, $params)->has_no_error('Withdrawal allowed from svg mt5 account when sibling labuan account is withdrawal-locked');
    cmp_ok $test_client->default_account->balance, '==', 820 + 150 + 50, "Correct balance after withdrawal";

    $test_client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data)});
    $test_client->save;
    $account_mock->mock('_fetch_mt5_lc', sub { return LandingCompany::Registry::get('labuan'); });
    $params->{args}->{from_mt5} = 'MTR' . $ACCOUNTS{'real\svg'};
    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    $c->call_ok($method, $params)->has_no_error('Withdrawal unlocked for labuan mt5 after financial assessment');
    cmp_ok $test_client->default_account->balance, '==', 820 + 150 + 100, "Correct balance after withdrawal";

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
};

subtest 'mf_withdrawal' => sub {
    my $test_mf_client = create_client('MF');
    $test_mf_client->account('USD');
    $test_mf_client->status->set('financial_risk_approval', 'system', 'Accepted approval');
    $test_mf_client->tax_residence('de');
    $test_mf_client->tax_identification_number('111-222-333');
    $test_mf_client->email($DETAILS{email});
    $test_mf_client->status->clear_age_verification;

    $user->add_client($test_mf_client);

    my $token_mf = $m->create_token($test_mf_client->loginid, 'test token');

    my $params_mf = {
        language => 'EN',
        token    => $token_mf,
        args     => {
            from_mt5  => 'MTR' . $ACCOUNTS{'real\svg'},
            to_binary => $test_mf_client->loginid,
            amount    => 350,
        },
    };

    BOM::RPC::v3::MT5::Account::reset_throttler($test_mf_client->loginid);

    my $method = "mt5_withdrawal";

    my $demo_account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $demo_account_mock->mock('_fetch_mt5_lc', sub { return LandingCompany::Registry::get('maltainvest'); });
    $test_mf_client->set_authentication('ID_DOCUMENT', {status => 'pending'});
    $c->call_ok($method, $params_mf)->has_error('Withdrawal request failed.')
        ->error_code_is('MT5WithdrawalError', 'error code is MT5WithdrawalError')->error_message_like(qr/authenticate/);

    my $mocked_client = Test::MockModule->new(ref($test_mf_client));
    $mocked_client->mock('has_valid_documents', sub { 1 });
    $test_mf_client->set_authentication('ID_DOCUMENT', {status => 'pass'});

    BOM::RPC::v3::MT5::Account::reset_throttler($test_mf_client->loginid);

    $c->call_ok($method, $params_mf)->has_no_error('no error for mt5_withdrawal when client authenticated');

    cmp_ok $test_mf_client->default_account->balance, '==', 350, "Correct balance after withdrawal";

    $mocked_client->unmock_all;
    $demo_account_mock->unmock;
};

subtest 'mf_deposit' => sub {
    my $test_mf_client = create_client('MF');
    $test_mf_client->account('USD');
    top_up $test_mf_client, USD => 1000;

    $test_mf_client->email($DETAILS{email});
    $test_mf_client->status->clear_age_verification;

    $user->add_client($test_mf_client);

    my $token_mf = $m->create_token($test_mf_client->loginid, 'test token');

    my $params_mf = {
        language => 'EN',
        token    => $token_mf,
        args     => {
            from_binary => $test_mf_client->loginid,
            to_mt5      => 'MTR' . $ACCOUNTS{'real\svg'},
            amount      => 350,
        },
    };

    BOM::RPC::v3::MT5::Account::reset_throttler($test_mf_client->loginid);

    my $method = "mt5_deposit";

    my $demo_account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $demo_account_mock->mock('_fetch_mt5_lc', sub { return LandingCompany::Registry::get('maltainvest'); });
    $test_mf_client->set_authentication('ID_DOCUMENT', {status => 'pending'});
    $c->call_ok($method, $params_mf)->has_error('Deposit request failed.')->error_code_is('MT5DepositError', 'error code is MT5DepositError')
        ->error_message_like(qr/authenticate/);

    my $mocked_client = Test::MockModule->new(ref($test_mf_client));
    $mocked_client->mock('has_valid_documents', sub { 1 });

    $test_mf_client->set_authentication('ID_DOCUMENT', {status => 'pass'});

    BOM::RPC::v3::MT5::Account::reset_throttler($test_mf_client->loginid);

    $c->call_ok($method, $params_mf)->has_error('Deposit failed.')->error_message_like(qr/Financial Risk approval is required./);
    $test_mf_client->status->set('financial_risk_approval', 'SYSTEM', 'Client accepted financial risk disclosure');
    $c->call_ok($method, $params_mf)->has_error('Deposit failed.')
        ->error_message_like(qr/Tax-related information is mandatory for legal and regulatory requirements/);
    $test_mf_client->tax_residence('de');
    $test_mf_client->tax_identification_number('111-222-333');
    $test_mf_client->save;

    $c->call_ok($method, $params_mf)->has_no_error('no error for mt5_deposit');

    cmp_ok $test_mf_client->default_account->balance, '==', 650, "Correct balance after deposit";

    $mocked_client->unmock_all;
    $demo_account_mock->unmock;
};
subtest 'labuan deposit' => sub {

    my $loginid = $test_client->loginid;
    $test_client->financial_assessment({data => '{}'});
    $test_client->save();

    my $method = "mt5_deposit";
    $params = {
        language => 'EN',
        token    => $token,
        args     => {
            to_mt5      => 'MTR' . $ACCOUNTS{'real\labuan_financial_stp'},
            from_binary => $test_client->loginid,
            amount      => 20,
        },
    };

    set_absolute_time(Date::Utility->new('2018-02-15')->epoch);

    my $account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $account_mock->mock('_fetch_mt5_lc', sub { return LandingCompany::Registry::get('labuan'); });

    BOM::RPC::v3::MT5::Account::reset_throttler($loginid);
    my $mocked_client = Test::MockModule->new(ref($test_client));
    $mocked_client->mock('has_valid_documents', sub { 1 });
    $c->call_ok($method, $params)->has_no_error('Deposit allowed to enable labuan mt5 account');
    cmp_ok $test_client->default_account->balance, '==', 1050, "Correct balance after deposit";

    BOM::RPC::v3::MT5::Account::reset_throttler($loginid);
    $manager_module->mock(
        'get_group',
        sub {
            return Future->done({
                'leverage' => 300,
                'currency' => 'USD',
                'group'    => 'real\labuan_financial_stp',
                'company'  => 'Deriv (SVG) LLC'
            });
        });
    # Returning invalid rights will block deposit.
    $manager_module->mock(
        'get_user',
        sub {
            return Future->done({
                email   => 'test.account@binary.com',
                name    => 'Meta traderman',
                balance => '1234',
                country => 'Malta',
                rights  => 999,
                group   => 'real\labuan_financial_stp',
                'login' => 'MTR00000015',
            });
        });
    $c->call_ok($method, $params)->has_error('client is disable')
        ->error_code_is('MT5DepositLocked', 'Deposit is locked when mt5 account is disabled for labuan');

    cmp_ok $test_client->default_account->balance, '==', 1050, "Balance has not changed because mt5 account is locked";
    $manager_module->unmock('get_user', 'get_group');
    # Using enable rights 482 should enable transfer.
    $c->call_ok($method, $params)->has_no_error('Deposit allowed when mt5 account gets enabled');
    cmp_ok $test_client->default_account->balance, '==', 1030, "Correct balance after deposit";

};

done_testing();

