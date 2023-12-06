use strict;
use warnings;
use Guard;
use Test::More;
use Test::Mojo;
use Test::MockModule;
use Test::MockObject;
use Test::MockTime qw(:all);
use JSON::MaybeUTF8;

use LandingCompany::Registry;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::RPC::QueueClient;
use BOM::Test::Helper::Client qw(create_client top_up);
use BOM::MT5::User::Async;
use BOM::Platform::Token;
use BOM::User;
use BOM::Config::Runtime;

use Test::BOM::RPC::Accounts;

my $c = BOM::Test::RPC::QueueClient->new();
BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->MT5(999);

# disable routing to demo p01_ts02
my $p01_ts02_load = BOM::Config::Runtime->instance->app_config->system->mt5->load_balance->demo->all->p01_ts02;
BOM::Config::Runtime->instance->app_config->system->mt5->load_balance->demo->all->p01_ts02(0);

# disable routing to demo p01_ts03
my $p01_ts03_load = BOM::Config::Runtime->instance->app_config->system->mt5->load_balance->demo->all->p01_ts03;
BOM::Config::Runtime->instance->app_config->system->mt5->load_balance->demo->all->p01_ts03(0);

my $runtime_system  = BOM::Config::Runtime->instance->app_config->system;
my $runtime_payment = BOM::Config::Runtime->instance->app_config->payments;

# unlimit daily transfer
$runtime_payment->transfer_between_accounts->limits->MT5(999);

scope_guard { restore_time() };

my $documents_mock = Test::MockModule->new('BOM::User::Client::AuthenticationDocuments');
my $expired_documents;
my $expired_enforced;
my $outdated_poa;

$documents_mock->mock(
    'expired',
    sub {
        my ($self, $enforce) = @_;

        $expired_enforced ||= $enforce;

        return $expired_documents if defined $expired_documents;
        return $documents_mock->original('expired')->(@_);
    });
$documents_mock->mock(
    'outdated',
    sub {
        my ($self) = @_;

        return $outdated_poa if defined $outdated_poa;
        return $documents_mock->original('outdated')->(@_);
    });
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

my $test_wallet_vr = create_client('VRW');
$test_wallet_vr->email($DETAILS{email});
$test_wallet_vr->set_default_account('USD');
$test_wallet_vr->save;

my $user = BOM::User->create(
    email    => $DETAILS{email},
    password => 's3kr1t',
);
$user->update_trading_password($DETAILS{password}{main});
$user->add_client($test_client);
$user->add_client($test_client_vr);
$user->add_client($test_wallet_vr);

my $m        = BOM::Platform::Token::API->new;
my $token    = $m->create_token($test_client->loginid,    'test token');
my $token_vr = $m->create_token($test_client_vr->loginid, 'test token');

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
$c->call_ok('mt5_new_account', $params)->has_no_error('no error for mt5_new_account');

$params->{args}->{account_type} = 'demo';
$c->call_ok('mt5_new_account', $params)->has_no_error('no error for mt5_new_account')->result;

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
            to_mt5      => 'MTR' . $ACCOUNTS{'real\p01_ts03\synthetic\svg_std_usd\01'},
            amount      => 180,
        },
    };

    set_absolute_time(Date::Utility->new('2018-02-15')->epoch);

    my $demo_account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $demo_account_mock->mock('_fetch_mt5_lc', sub { return LandingCompany::Registry->by_name('svg'); });

    my $mt5_async_mock = Test::MockModule->new('BOM::MT5::User::Async');
    $mt5_async_mock->mock('is_suspended', sub { return undef; });

    $c->call_ok($method, $params)->has_no_error('no error for mt5_deposit');
    ok(defined $c->result->{binary_transaction_id}, 'result has a transaction ID');
    subtest record_mt5_transfer_deposit => sub {
        my $mt5_transfer = _get_mt5transfer_from_transaction($test_client->db->dbic, $c->result->{binary_transaction_id});
        is($mt5_transfer->{mt5_amount}, -180, 'Correct amount recorded');
    };
    # assert that account balance is now 1000-180 = 820
    cmp_ok $test_client->default_account->balance, '==', 820, "Correct balance after deposited to mt5 account";

    $runtime_system->suspend->experimental_currencies(['USD']);
    $c->call_ok($method, $params)->has_error('error as currency is experimental')->error_code_is('Experimental', 'error code is Experimental')
        ->error_message_is('This currency is temporarily suspended. Please select another currency to proceed.');
    $runtime_system->suspend->experimental_currencies([]);

    $test_client->status->set('no_withdrawal_or_trading', 'system', 'pending investigations');
    $c->call_ok($method, $params)->has_error('client is blocked from withdrawal')->error_code_is('MT5DepositError', 'error code is MT5DepositError')
        ->error_message_is('You cannot perform this action, as your account is withdrawal locked.');
    $test_client->status->clear_no_withdrawal_or_trading;

    $params->{args}{to_mt5} = "MTwrong";
    $c->call_ok($method, $params)->has_error('error for mt5_deposit wrong login')
        ->error_code_is('InvalidLoginid', 'error code for mt5_deposit wrong login');

    $test_client->status->set('mt5_withdrawal_locked', 'system', 'testing');
    $params->{args}{to_mt5} = 'MTR' . $ACCOUNTS{'real\p01_ts03\synthetic\svg_std_usd\01'};
    $c->call_ok($method, $params)->has_error('client is blocked from withdrawal')->error_code_is('MT5DepositError', 'error code is MT5DepositError')
        ->error_message_is('You cannot perform this action, as your account is withdrawal locked.');
    $test_client->status->clear_mt5_withdrawal_locked;

    my $mock_client  = Test::MockModule->new('BOM::User::Client');
    my $tier_details = {};
    $mock_client->redefine(
        get_payment_agent => sub {
            my $result = Test::MockObject->new();
            $result->mock(status       => sub { 'authorized' });
            $result->mock(tier_details => sub { $tier_details });

            return $result;
        });

    $c->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('ServiceNotAllowedForPA', 'Payment agents cannot make MT5 deposits.')
        ->error_message_is('This service is not available for payment agents.', 'Error message is about PAs');

    $tier_details = {
        cashier_withdraw => 0,
        p2p              => 0,
        trading          => 1,
        transfer_to_pa   => 0
    };

    $c->call_ok($method, $params)->has_no_system_error->has_no_error('PA can deposit if trading permission exists');

    $mock_client->unmock_all;
    $demo_account_mock->unmock_all();
    top_up $test_client, USD => $params->{args}{amount};
};

subtest 'deposit_exceeded_balance' => sub {
    # User needs some real money now
    cmp_ok $test_client->default_account->balance, '==', 820, "balance before a failed MT5 deposit";

    my $loginid = $test_client->loginid;

    my $method = "mt5_deposit";
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            from_binary => $loginid,
            to_mt5      => 'MTR' . $ACCOUNTS{'real\p01_ts03\synthetic\svg_std_usd\01'},
            amount      => 1000,
        },
    };

    set_absolute_time(Date::Utility->new('2018-02-15')->epoch);

    my $demo_account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $demo_account_mock->mock('_fetch_mt5_lc', sub { return LandingCompany::Registry->by_name('svg'); });

    $c->call_ok($method, $params)->has_error('Failed MT5 Deposit')->error_code_is('MT5DepositError')
        ->error_message_like(qr/The maximum amount you may transfer is: 820.00./, 'Balance exceeded');
    is($c->result->{binary_transaction_id}, undef, 'result does not have a transaction ID');
    subtest record_mt5_transfer_deposit => sub {
        my $mt5_transfer = _get_mt5transfer_from_transaction($test_client->db->dbic, $c->result->{binary_transaction_id});
        is($mt5_transfer->{mt5_amount}, undef, 'No amount recorded');
    };

    cmp_ok $test_client->default_account->balance, '==', 820, "Correct balance after a failed MT5 deposit";

    $demo_account_mock->unmock_all();

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
    $test_client->myaffiliates_token("");
    $test_client->save;
};

subtest 'virtual topup' => sub {
    my $method = "mt5_new_account";

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

    my $demo_account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $demo_account_mock->mock('_is_account_demo', sub { return 1 });
    $demo_account_mock->mock('_fetch_mt5_lc',    sub { return LandingCompany::Registry->by_name('iom'); });

    $method = "mt5_deposit";
    my $deposit_demo_params = {
        language => 'EN',
        token    => $token,
        args     => {
            to_mt5 => 'MTR' . $ACCOUNTS{'real\p01_ts03\synthetic\svg_std_usd\01'},
            amount => 180,
        },
    };

    $c->call_ok($method, $deposit_demo_params)->has_error('Cannot Deposit')->error_code_is('MT5DepositError')
        ->error_message_like(qr/balance falls below 1000.00 USD/, 'Balance is higher');

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

    $demo_account_mock->unmock_all();
};

subtest 'virtual deposit' => sub {
    my $loginid = $test_client->loginid;

    my $method = "mt5_deposit";
    my $params = {
        language => 'EN',
        token    => $token_vr,
        args     => {
            from_binary => $loginid,
            to_mt5      => 'MTD' . $ACCOUNTS{'demo\p01_ts01\synthetic\svg_std_usd'},
            amount      => 180,
        },
    };

    set_absolute_time(Date::Utility->new('2018-02-15')->epoch);

    my $demo_account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $demo_account_mock->mock('_fetch_mt5_lc', sub { return LandingCompany::Registry->by_name('svg'); });

    $c->call_ok($method, $params)->has_error('Cannot depoosit to demo mt5 from real trading account')
        ->error_message_is('Transfer between real and virtual accounts is not allowed.', 'Demo to real error message');

    is $test_wallet_vr->default_account->balance, 0, "Correct balance after deposited to mt5 account";
    $params->{args}->{from_binary} = $test_client_vr->loginid;

    $c->call_ok($method, $params)->has_error('fail to deposit from virtual trading account')
        ->error_code_is('TransferBlockedClientIsVirtual', 'Deposit to demo MT5 from virtual trading account is not allowed');

    $params->{token} = $m->create_token($test_wallet_vr->loginid, 'test token');
    $params->{args}->{from_binary} = $test_wallet_vr->loginid;

    $c->call_ok($method, $params)->error_code_is('TransferBlockedWalletNotLinked', 'Cannot deposit to unlinked trading account');
    $test_wallet_vr->user->link_wallet_to_trading_account({
            wallet_id => $test_wallet_vr->loginid,
            client_id => 'MTD' . $ACCOUNTS{'demo\p01_ts01\synthetic\svg_std_usd'}});

    $c->call_ok($method, $params)->has_error('fail to deposit from an empty wallet')->error_code_is('MT5DepositError')
        ->error_message_like(qr/account has zero balance/, 'Deposit from empty wallet fails.');

    top_up $test_wallet_vr, USD => 180;
    $c->call_ok($method, $params)->has_no_error('no error for mt5_withdrawal');
    ok(defined $c->result->{binary_transaction_id}, 'Virtual wallet to demo MT5 transfer is allowed');

    is $test_wallet_vr->default_account->balance + 0, 0, "Correct balance after deposited to mt5 account";

    $demo_account_mock->unmock_all();
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
            to_mt5      => 'MTR' . $ACCOUNTS{'real\p01_ts03\synthetic\svg_std_usd\01'},
            amount      => 180,
        },
    };

    my $demo_account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $demo_account_mock->mock('_fetch_mt5_lc', sub { return LandingCompany::Registry->by_name('maltainvest'); });

    my $method = "mt5_deposit";

    $c->call_ok($method, $params_mx)->has_error('Cannot access MT5 as MX')
        ->error_code_is('MT5DepositError', 'Transfers to MT5 not allowed error_code')->error_message_like(qr/not allow MT5 trading/);
    $demo_account_mock->unmock_all();
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
            from_mt5  => 'MTR' . $ACCOUNTS{'real\p01_ts03\synthetic\svg_std_usd\01'},
            to_binary => $test_mx_client->loginid,
            amount    => 350,
        },
    };

    my $method = "mt5_withdrawal";

    my $demo_account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $demo_account_mock->mock('_fetch_mt5_lc', sub { return LandingCompany::Registry->by_name('maltainvest'); });

    $c->call_ok($method, $params_mx)->has_error('Cannot access MT5 as MX')->error_code_is('MT5WithdrawalError', 'error code is MT5WithdrawalError')
        ->error_message_like(qr/not allow MT5 trading/);
    $demo_account_mock->unmock_all();
};

subtest 'withdrawal' => sub {
    # TODO(leonerd): assertions in here about balance amounts would be
    #   sensitive to results of the previous test of mt5_deposit.
    my $method = "mt5_withdrawal";
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            from_mt5  => 'MTR' . $ACCOUNTS{'real\p01_ts03\synthetic\svg_std_usd\01'},
            to_binary => $test_client_vr->loginid,
            amount    => 150,
        },
    };

    set_absolute_time(Date::Utility->new('2018-02-15')->epoch);

    my $demo_account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $demo_account_mock->mock('_fetch_mt5_lc', sub { return LandingCompany::Registry->by_name('svg'); });

    $c->call_ok($method, $params)->has_error('cannot withdrawals from real mt5 to virtual trading account')
        ->error_message_is('Transfer between real and virtual accounts is not allowed.');

    $params->{args}->{to_binary} = $test_client->loginid;
    $params->{token} = $token_vr;
    $c->call_ok($method, $params)->has_error('fail withdrawals with vr_token')
        ->error_code_is('TransferBlockedClientIsVirtual', 'error code is PermissionDenied');

    $params->{token} = $token;
    $c->call_ok($method, $params)->has_no_error('no error for mt5_withdrawal');
    ok(defined $c->result->{binary_transaction_id}, 'result has a transaction ID');

    cmp_ok $test_client->default_account->balance, '==', 820 + 150, "Correct balance after withdrawal";

    subtest record_mt5_transfer_withdrawal => sub {
        my $mt5_transfer = _get_mt5transfer_from_transaction($test_client->db->dbic, $c->result->{binary_transaction_id});

        is($mt5_transfer->{mt5_amount}, 150, 'Correct amount recorded');
    };

    $runtime_system->suspend->experimental_currencies(['USD']);
    $c->call_ok($method, $params)->has_error('error as currency is experimental')->error_code_is('Experimental', 'error code is Experimental')
        ->error_message_is('This currency is temporarily suspended. Please select another currency to proceed.');
    $runtime_system->suspend->experimental_currencies([]);

    $params->{args}{from_mt5} = "MTwrong";
    $c->call_ok($method, $params)->has_error('error for mt5_withdrawal wrong login')
        ->error_code_is('InvalidLoginid', 'error code for mt5_withdrawal wrong login');

    $demo_account_mock->unmock_all();
};

subtest 'virtual withdrawal' => sub {
    my $method = "mt5_withdrawal";
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            from_mt5  => 'MTD' . $ACCOUNTS{'demo\p01_ts01\synthetic\svg_std_usd'},
            to_binary => $test_client->loginid,
            amount    => 150,
        },
    };

    set_absolute_time(Date::Utility->new('2018-02-15')->epoch);

    my $demo_account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $demo_account_mock->mock('_fetch_mt5_lc', sub { return LandingCompany::Registry->by_name('svg'); });

    $c->call_ok($method, $params)->has_error('Cannot withdrawals from demo mt5 to real trading account')
        ->error_message_is('Transfer between real and virtual accounts is not allowed.', 'Demo to real error message');

    $params->{args}->{to_binary} = $test_client_vr->loginid;
    $c->call_ok($method, $params)->has_error('fail withdrawals with vr_token')
        ->error_code_is('TransferBlockedWalletNotLinked', 'Withdrawal from demo MT5 to VRTC account is not allowed');

    $params->{args}->{to_binary} = $test_wallet_vr->loginid;
    $c->call_ok($method, $params)->has_no_error('no error for mt5_withdrawal');
    ok(defined $c->result->{binary_transaction_id}, 'Demo to virtual wallet transfer is allowed');

    is $test_wallet_vr->default_account->balance + 0, 150, "Correct balance after withdrawal from mt5 account";

    $demo_account_mock->unmock_all();
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
    is($c->result->{login},           'MTR' . $ACCOUNTS{'real\p01_ts01\financial\labuan_stp_usd'}, 'result->{login}');
    is($c->result->{balance},         0,                                                           'Balance is 0 upon creation');
    is($c->result->{display_balance}, '0.00',                                                      'Display balance is "0.00" upon creation');

    $test_client->financial_assessment({data => '{}'});
    $test_client->save();

    $method = "mt5_withdrawal";
    $params = {
        language => 'EN',
        token    => $token,
        args     => {
            from_mt5  => 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\labuan_stp_usd'},
            to_binary => $test_client->loginid,
            amount    => 50,
        },
    };

    set_absolute_time(Date::Utility->new('2018-02-15')->epoch);

    my $mocked_client = Test::MockModule->new(ref($test_client));
    $mocked_client->mock(get_poi_status_jurisdiction => sub { return 'verified' });
    $mocked_client->mock(get_poa_status              => sub { return 'verified' });

    my $account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $account_mock->mock('_fetch_mt5_lc', sub { return LandingCompany::Registry->by_name('labuan'); });

    my $mocked_status = Test::MockModule->new(ref($test_client->status));
    $mocked_status->mock('cashier_locked', sub { return 1 });

    $c->call_ok($method, $params)->has_error('request failed as client with cashier locked status set cannot withdraw')
        ->error_code_is('MT5WithdrawalError', 'error code is MT5WithdrawalError')
        ->error_message_is('Your account cashier is locked. Please contact us for more information.');

    $mocked_status->unmock_all;
    $expired_documents = 1;

    $c->call_ok($method, $params)->has_error('request failed as labuan needs to have valid documents')
        ->error_code_is('MT5WithdrawalError', 'error code is MT5WithdrawalError')
        ->error_message_is(
        'Your identity documents have expired. Visit your account profile to submit your valid documents and unlock your cashier.');

    $expired_documents = 0;

    $c->call_ok($method, $params)->has_no_error('Withdrawal allowed from labuan mt5 without FA before first deposit');
    cmp_ok $test_client->default_account->balance, '==', 820 + 150 + 50, "Correct balance after withdrawal";

    $c->call_ok(
        'mt5_deposit',
        {
            language => 'EN',
            token    => $token,
            args     => {
                to_mt5      => 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\labuan_stp_usd'},
                from_binary => $test_client->loginid,
                amount      => 50,
            },
        })->has_no_system_error->has_error->error_code_is('FinancialAssessmentRequired', 'Custom error code for FA required');

    $c->call_ok($method, $params)->has_no_error('Withdrawal is allowed.');

    $account_mock->mock('_fetch_mt5_lc', sub { return LandingCompany::Registry->by_name('svg'); });
    $params->{args}->{from_mt5} = 'MTR' . $ACCOUNTS{'real\p01_ts03\synthetic\svg_std_usd\01'};
    $c->call_ok($method, $params)->has_no_error('Withdrawal allowed from svg mt5 account when sibling labuan account is withdrawal-locked');
    cmp_ok $test_client->default_account->balance, '==', 820 + 150 + 50 + 100, "Correct balance after withdrawal";

    $test_client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data)});
    $test_client->save;
    $account_mock->mock('_fetch_mt5_lc', sub { return LandingCompany::Registry->by_name('labuan'); });
    $params->{args}->{from_mt5} = 'MTR' . $ACCOUNTS{'real\p01_ts03\synthetic\svg_std_usd\01'};
    $c->call_ok($method, $params)->has_no_error('Withdrawal unlocked for labuan mt5 after financial assessment');
    cmp_ok $test_client->default_account->balance, '==', 820 + 150 + 200, "Correct balance after withdrawal";

    # enforcement depends on whether the client has mt5 regulated accounts or not
    ok $user->has_mt5_regulated_account(use_mt5_conf => 1), 'User has mt5 regulated';

    $expired_enforced  = undef;
    $outdated_poa      = 1;
    $expired_documents = 0;
    $c->call_ok($method, $params)->has_error('Withdrawal failed.')->error_message_like(qr/Your identity documents have expired./);
    ok $expired_enforced, 'Expired docs';

    $expired_enforced  = undef;
    $outdated_poa      = 0;
    $expired_documents = 1;
    $c->call_ok($method, $params)->has_error('Withdrawal failed.')->error_message_like(qr/Your identity documents have expired./);
    ok $expired_enforced, 'Expired was forced';

    $expired_enforced  = undef;
    $outdated_poa      = 1;
    $expired_documents = 1;
    $c->call_ok($method, $params)->has_error('Withdrawal failed.')->error_message_like(qr/Your identity documents have expired./);
    ok $expired_enforced, 'Expired was forced';

    $expired_enforced  = undef;
    $expired_documents = 0;
    $outdated_poa      = 0;
    $c->call_ok($method, $params)->has_no_error('Withdrawal succeded.');
    ok $expired_enforced, 'Expired was enforced';

    $test_client->status->clear_mt5_withdrawal_locked;
    $test_client->status->_build_all;

    $outdated_poa     = 1;
    $expired_enforced = undef;
    $c->call_ok(
        'mt5_deposit',
        {
            language => 'EN',
            token    => $token,
            args     => {
                to_mt5      => 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\labuan_stp_usd'},
                from_binary => $test_client->loginid,
                amount      => 50,
            },
        })->has_no_error('Deposit does not enforces expiration/outdated checks');
    ok $expired_enforced, 'Expired check was enforced';

    $expired_documents = undef;
    $outdated_poa      = undef;
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
            from_mt5  => 'MTR' . $ACCOUNTS{'real\p01_ts03\synthetic\svg_std_usd\01'},
            to_binary => $test_mf_client->loginid,
            amount    => 350,
        },
    };

    my $method = "mt5_withdrawal";

    my $demo_account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $demo_account_mock->mock('_fetch_mt5_lc', sub { return LandingCompany::Registry->by_name('maltainvest'); });
    $test_mf_client->set_authentication('ID_DOCUMENT', {status => 'pending'});
    $c->call_ok($method, $params_mf)->has_error('Withdrawal request failed.')
        ->error_code_is('MT5WithdrawalError', 'error code is MT5WithdrawalError')->error_message_like(qr/authenticate/);

    my $mocked_client = Test::MockModule->new(ref($test_mf_client));
    $mocked_client->mock(is_financial_assessment_complete => 1);

    $expired_documents = undef;

    $test_mf_client->set_authentication('ID_DOCUMENT', {status => 'pass'});

    $c->call_ok($method, $params_mf)->has_no_error('no error for mt5_withdrawal when client authenticated');

    cmp_ok $test_mf_client->default_account->balance, '==', 350, "Correct balance after withdrawal";

    $expired_documents = 1;

    # enforcement depends on whether the client has mt5 regulated accounts or not
    my $user_mock = Test::MockModule->new(ref($user));
    $user_mock->mock(
        'has_mt5_regulated_account',
        sub {
            return 0;
        });

    ok !$user->has_mt5_regulated_account(use_mt5_conf => 1), 'User does not have mt5 regulated';

    $expired_enforced  = undef;
    $expired_documents = 1;
    $outdated_poa      = 0;
    $c->call_ok($method, $params_mf)->has_error('Withdrawal failed.')->error_message_like(qr/Your identity documents have expired./);
    ok !$expired_enforced, 'Expiration check was not enforced';

    $expired_enforced  = undef;
    $expired_documents = 0;
    $outdated_poa      = 1;
    $c->call_ok($method, $params_mf)->has_no_error('Withdrawal succeded (POA is not checked on this scenario).');
    ok !$expired_enforced, 'Expiration check was not enforced';

    $expired_enforced  = undef;
    $expired_documents = 0;
    $outdated_poa      = 0;
    $c->call_ok($method, $params_mf)->has_no_error('Withdrawal succeded.');
    ok !$expired_enforced, 'Expiration check was not enforced';

    $expired_documents = undef;
    $demo_account_mock->unmock_all();
    $user_mock->unmock_all();
};

subtest 'mf_deposit' => sub {
    $expired_documents = 1;
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
            to_mt5      => 'MTR' . $ACCOUNTS{'real\p01_ts03\synthetic\svg_std_usd\01'},
            amount      => 350,
        },
    };

    my $method = "mt5_deposit";

    my $demo_account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $demo_account_mock->mock('_fetch_mt5_lc', sub { return LandingCompany::Registry->by_name('maltainvest'); });
    $test_mf_client->set_authentication('ID_DOCUMENT', {status => 'pending'});
    $c->call_ok($method, $params_mf)->has_error('Deposit request failed.')->error_code_is('MT5DepositError', 'error code is MT5DepositError')
        ->error_message_like(qr/authenticate/);

    my $mocked_client = Test::MockModule->new(ref($test_mf_client));
    $mocked_client->mock(is_financial_assessment_complete => 1);

    $expired_documents = undef;

    $test_mf_client->set_authentication('ID_DOCUMENT', {status => 'pass'});

    $c->call_ok($method, $params_mf)->has_error('Deposit failed.')->error_message_like(qr/Financial Risk approval is required./);
    $test_mf_client->status->set('financial_risk_approval', 'SYSTEM', 'Client accepted financial risk disclosure');
    $c->call_ok($method, $params_mf)->has_error('Deposit failed.')
        ->error_message_like(qr/Tax-related information is mandatory for legal and regulatory requirements/);
    $test_mf_client->tax_residence('de');
    $test_mf_client->tax_identification_number('111-222-333');
    $test_mf_client->save;
    $expired_enforced = undef;
    $c->call_ok($method, $params_mf)->has_no_error('no error for mt5_deposit');
    ok $expired_enforced, 'Expiration check was enforced';

    cmp_ok $test_mf_client->default_account->balance, '==', 650, "Correct balance after deposit";
    $expired_documents = 1;
    $demo_account_mock->unmock_all();
};

subtest 'labuan deposit' => sub {
    $expired_documents = 1;

    my $loginid = $test_client->loginid;
    $test_client->financial_assessment({data => '{}'});
    $test_client->save();

    my $method = "mt5_deposit";
    $params = {
        language => 'EN',
        token    => $token,
        args     => {
            to_mt5      => 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\labuan_stp_usd'},
            from_binary => $test_client->loginid,
            amount      => 20,
        },
    };

    set_absolute_time(Date::Utility->new('2018-02-15')->epoch);

    my $account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $account_mock->mock('_fetch_mt5_lc', sub { return LandingCompany::Registry->by_name('labuan'); });

    $expired_documents = undef;
    $c->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('FinancialAssessmentRequired', 'Custom error code for FA required');

    $manager_module->mock(
        'get_group',
        sub {
            return Future->done({
                'leverage' => 300,
                'currency' => 'USD',
                'group'    => 'real\p01_ts01\financial\labuan_stp_usd',
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
                group   => 'real\p01_ts01\financial\labuan_stp_usd',
                'login' => 'MTR00001015',
            });
        });
    $account_mock->mock(_is_financial_assessment_complete => sub { return 1 });
    $c->call_ok($method, $params)->has_error('client is disable')
        ->error_code_is('MT5DepositLocked', 'Deposit is locked when mt5 account is disabled for labuan');

    cmp_ok $test_client->default_account->balance, '==', 820 + 150 + 200, "Balance has not changed because mt5 account is locked";
    $manager_module->unmock('get_user', 'get_group');
    $c->call_ok($method, $params)->has_error('You cannot perform this action, as your account is withdrawal locked.');
    $test_client->status->clear_mt5_withdrawal_locked;
    # Using enable rights 482 should enable transfer.
    $c->call_ok($method, $params)->has_no_error('Deposit allowed when mt5 account gets enabled');
    cmp_ok $test_client->default_account->balance, '==', 820 + 150 + 200 - 20, "Correct balance after deposit";
    $expired_documents = 0;
    $expired_documents = undef;
    $expired_enforced  = undef;
    $c->call_ok($method, $params)->has_no_error('Deposit succeded');
    ok $expired_enforced, 'Expiration check was enforced';
    $account_mock->unmock('_is_financial_assessment_complete');
    $expired_documents = 1;
};

subtest 'bvi withdrawal' => sub {
    $expired_documents = undef;
    my $new_email  = 'bvi_withdraw' . $DETAILS{email};
    my $new_client = create_client('CR', undef, {residence => 'br'});
    my $token      = $m->create_token($new_client->loginid, 'test token 2');
    $new_client->set_default_account('USD');
    $new_client->email($new_email);
    $new_client->tax_identification_number('1234');
    $new_client->tax_residence('br');
    $new_client->account_opening_reason('speculative');
    $new_client->place_of_birth('br');
    $new_client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data)});

    my $user = BOM::User->create(
        email    => $new_email,
        password => 'red1rectMeToBVI',
    );
    $user->update_trading_password($DETAILS{password}{main});
    $user->add_client($new_client);
    $new_client->save;

    my $method = 'mt5_new_account';
    my $params = {
        token => $token,
        args  => {
            account_type     => 'financial',
            country          => 'br',
            email            => $new_email,
            name             => $DETAILS{name},
            mainPassword     => $DETAILS{password}{main},
            leverage         => 1000,
            mt5_account_type => 'financial',
            company          => 'bvi'
        },
    };

    my $user_client_mock = Test::MockModule->new('BOM::User::Client');
    $user_client_mock->mock(
        'get_poi_status_jurisdiction',
        sub {
            return 'verified';
        });
    $user_client_mock->mock(
        'get_poa_status',
        sub {
            return 'verified';
        });

    $c->call_ok($method, $params)->has_no_error('no error creating mt5 account');
    is($c->result->{login},           'MTR' . $ACCOUNTS{'real\p01_ts01\financial\bvi_std_usd'}, 'New bvi account correct login id');
    is($c->result->{balance},         0,                                                        'Balance is 0 upon creation');
    is($c->result->{display_balance}, '0.00',                                                   'Display balance is "0.00" upon creation');

    $manager_module->mock(
        'get_group',
        sub {
            return Future->done({
                'leverage' => 300,
                'currency' => 'USD',
                'group'    => 'real\p01_ts01\financial\bvi_std_usd',
                'company'  => 'Deriv (SVG) LLC'
            });
        });
    $manager_module->mock(
        'get_user',
        sub {
            return Future->done({
                email   => 'test.account@binary.com',
                name    => 'Meta traderman',
                balance => '1234',
                country => 'Malta',
                rights  => 482,
                group   => 'real\p01_ts01\financial\bvi_std_usd',
                'login' => 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\bvi_std_usd'},
            });
        });

    my $bom_user_mock     = Test::MockModule->new('BOM::User');
    my $mock_logindetails = {
        CR10001 => {
            account_type   => undef,
            attributes     => {},
            creation_stamp => "2022-09-14 07:13:52.727067",
            currency       => undef,
            loginid        => "CR10001",
            platform       => 'dtrade',
            is_virtual     => 0,
            is_external    => 0,
            status         => undef,
        },
        MTR1001018 => {
            account_type => "real",
            attributes   => {
                account_type    => "real",
                currency        => "USD",
                group           => "real\\p01_ts01\\financial\\bvi_std_usd",
                landing_company => "svg",
                leverage        => 300,
                market_type     => "financial",
            },
            creation_stamp => "2018-02-10 07:13:52.94334",
            currency       => "USD",
            loginid        => "MTR1001018",
            platform       => "mt5",
            is_virtual     => 0,
            is_external    => 1,
            status         => 'poa_pending',
        },
        MTR1001019 => {
            account_type => "real",
            attributes   => {
                account_type    => "real",
                currency        => "USD",
                group           => "real\\p01_ts01\\financial\\bvi_std_usd",
                landing_company => "svg",
                leverage        => 300,
                market_type     => "financial",
            },
            creation_stamp => "2018-02-09 07:13:52.94334",
            currency       => "USD",
            loginid        => "MTR1001019",
            platform       => "mt5",
            is_virtual     => 0,
            is_external    => 1,
            status         => 'poa_pending',
        },
        MTR1001017 => {
            account_type => "real",
            attributes   => {
                account_type    => "real",
                currency        => "USD",
                group           => "real\\p01_ts01\\financial\\vanuatu_std_usd",
                landing_company => "svg",
                leverage        => 300,
                market_type     => "financial",
            },
            creation_stamp => "2018-02-01 07:13:52.94334",
            currency       => "USD",
            loginid        => "MTR1001017",
            platform       => "mt5",
            is_virtual     => 0,
            is_external    => 1,
            status         => 'poa_pending',
        },
    };
    $bom_user_mock->mock(
        'loginid_details',
        sub {
            $mock_logindetails;
        });

    $method = "mt5_withdrawal";
    $params = {
        language => 'EN',
        token    => $token,
        args     => {
            from_mt5  => 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\bvi_std_usd'},
            to_binary => $new_client->loginid,
            amount    => 50,
        },
    };

    set_absolute_time(Date::Utility->new('2018-02-15')->epoch);
    $expired_documents = undef;
    my $account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $account_mock->mock('_fetch_mt5_lc', sub { return LandingCompany::Registry->by_name('bvi'); });

    # verified POA, false positive poa_failed, pass.
    $mock_logindetails->{MTR1001018}->{status} = 'poa_failed';
    $c->call_ok($method, $params)->has_no_error('withdrawal - verified POA, false positive poa_failed, pass');

    $user_client_mock->mock(
        'get_poa_status',
        sub {
            return 'pending';
        });

    $mock_logindetails->{MTR1001018}->{status} = 'poa_pending';

    # pending POA, within grace period, pass.
    $c->call_ok($method, $params)->has_no_error('withdrawal - pending POA, within grace period, pass');

    # pending POA, last day grace period, pass.
    $mock_logindetails->{MTR1001018}->{creation_stamp} = '2018-02-05 07:13:52.94334';
    $c->call_ok($method, $params)->has_no_error('withdrawal - pending POA, last day grace period, pass');

    # pending POA, post grace period, fail.
    $mock_logindetails->{MTR1001018}->{creation_stamp} = '2018-02-04 07:13:52.94334';
    $c->call_ok($method, $params)->has_error('Withdrawal failed.')
        ->error_message_like(qr/Proof of Address verification failed. Withdrawal operation suspended./);

    # pending POA, poa_failed, fail.
    $mock_logindetails->{MTR1001018}->{creation_stamp} = '2018-02-10 07:13:52.94334';
    $mock_logindetails->{MTR1001018}->{status}         = 'poa_failed';
    $c->call_ok($method, $params)->has_error('Withdrawal failed.')
        ->error_message_like(qr/Proof of Address verification failed. Withdrawal operation suspended./);

    $mock_logindetails->{MTR1001018}->{status} = 'poa_pending';
    # pending POA, mixed BVI and Vanuatu where vanuatu expired don't affect BVI within grace period, pass.
    $c->call_ok($method, $params)
        ->has_no_error('withdrawal - pending POA, mixed BVI and Vanuatu where vanuatu expired dont affect BVI within grace period, pass');

    # pending POA, multiple MT5 within grace period, pass
    $c->call_ok($method, $params)
        ->has_no_error('withdrawal - pending POA, mixed BVI and Vanuatu where vanuatu expired dont affect BVI within grace period, pass');

    # pending POA, selected MT5 within grace period but first account expired, fail
    $mock_logindetails->{MTR1001019}->{creation_stamp} = '2018-02-04 07:13:52.94334';
    $c->call_ok($method, $params)->has_error('Withdrawal failed.')
        ->error_message_like(qr/Proof of Address verification failed. Withdrawal operation suspended./);

    $mock_logindetails->{MTR1001019}->{creation_stamp} = Date::Utility->new()->date_yyyymmdd;
    $c->call_ok($method, $params)->has_no_error('withdrawal ok');

    # document expiration
    # outdated POA, poa_outdated, fail.
    $user_client_mock->mock(
        'get_poi_status',
        sub {
            return 'expired';
        });

    # enforcement depends on whether the client has mt5 regulated accounts or not
    ok $user->has_mt5_regulated_account(use_mt5_conf => 1), 'User has mt5 regulated';

    $expired_enforced  = undef;
    $outdated_poa      = 0;
    $expired_documents = 1;
    $c->call_ok($method, $params)->has_error('Withdrawal failed.')->error_message_like(qr/Your identity documents have expired./);
    ok $expired_enforced, 'Expired check was enforced';

    $expired_enforced  = undef;
    $outdated_poa      = 0;
    $expired_documents = 1;
    $c->call_ok($method, $params)->has_error('Withdrawal failed.')->error_message_like(qr/Your identity documents have expired./);
    ok $expired_enforced, 'Expired check was enforced';

    $expired_enforced  = undef;
    $outdated_poa      = 1;
    $expired_documents = 0;
    $c->call_ok($method, $params)->has_error('Withdrawal failed.')->error_message_like(qr/Your identity documents have expired./);
    ok $expired_enforced, 'Expired check was enforced';

    $expired_enforced  = undef;
    $expired_documents = 0;
    $outdated_poa      = 0;
    $c->call_ok($method, $params)->has_no_error('Withdrawal succeded.');
    ok $expired_enforced, 'Expired check was enforced';

    $manager_module->unmock('get_user', 'get_group');
    $user_client_mock->unmock('get_poi_status_jurisdiction', 'get_poa_status');
    $bom_user_mock->unmock('loginid_details');

    $outdated_poa      = undef;
    $expired_documents = undef;
};

subtest 'vanuatu withdrawal' => sub {
    $expired_documents = undef;
    my $new_email  = 'vanuatu_withdraw' . $DETAILS{email};
    my $new_client = create_client('CR', undef, {residence => 'br'});
    my $token      = $m->create_token($new_client->loginid, 'test token 2');
    $new_client->set_default_account('USD');
    $new_client->email($new_email);
    $new_client->tax_identification_number('1234');
    $new_client->tax_residence('br');
    $new_client->account_opening_reason('speculative');
    $new_client->place_of_birth('br');
    $new_client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data)});

    my $user = BOM::User->create(
        email    => $new_email,
        password => 'red1rectMeToBVI',
    );
    $user->update_trading_password($DETAILS{password}{main});
    $user->add_client($new_client);
    $new_client->save;

    my $method = 'mt5_new_account';
    my $params = {
        token => $token,
        args  => {
            account_type     => 'financial',
            country          => 'br',
            email            => $new_email,
            name             => $DETAILS{name},
            mainPassword     => $DETAILS{password}{main},
            leverage         => 1000,
            mt5_account_type => 'financial',
            company          => 'vanuatu'
        },
    };

    my $user_client_mock = Test::MockModule->new('BOM::User::Client');
    $user_client_mock->mock(
        'get_poi_status_jurisdiction',
        sub {
            return 'verified';
        });
    $user_client_mock->mock(
        'get_poa_status',
        sub {
            return 'verified';
        });

    $c->call_ok($method, $params)->has_no_error('no error creating mt5 account');
    is($c->result->{login},           'MTR' . $ACCOUNTS{'real\p01_ts01\financial\vanuatu_std-hr_usd'}, 'New vanuatu account correct login id');
    is($c->result->{balance},         0,                                                               'Balance is 0 upon creation');
    is($c->result->{display_balance}, '0.00',                                                          'Display balance is "0.00" upon creation');

    $manager_module->mock(
        'get_group',
        sub {
            return Future->done({
                'leverage' => 300,
                'currency' => 'USD',
                'group'    => 'real\p01_ts01\financial\vanuatu_std-hr_usd',
                'company'  => 'Deriv (SVG) LLC'
            });
        });
    $manager_module->mock(
        'get_user',
        sub {
            return Future->done({
                email   => 'test.account@binary.com',
                name    => 'Meta traderman',
                balance => '1234',
                country => 'Malta',
                rights  => 482,
                group   => 'real\p01_ts01\financial\vanuatu_std-hr_usd',
                'login' => 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\vanuatu_std-hr_usd'},
            });
        });

    my $bom_user_mock     = Test::MockModule->new('BOM::User');
    my $mock_logindetails = {
        CR10002 => {
            account_type   => undef,
            attributes     => {},
            creation_stamp => "2022-09-14 07:13:52.727067",
            currency       => undef,
            loginid        => "CR10002",
            platform       => 'dtrade',
            is_virtual     => 0,
            is_external    => 0,
            status         => undef,
        },
        MTR1001020 => {
            account_type => "real",
            attributes   => {
                account_type    => "real",
                currency        => "USD",
                group           => "real\\p01_ts01\\financial\\vanuatu_std_usd",
                landing_company => "svg",
                leverage        => 300,
                market_type     => "financial",
            },
            creation_stamp => "2018-02-13 07:13:52.94334",
            currency       => "USD",
            loginid        => "MTR1001020",
            platform       => "mt5",
            is_virtual     => 0,
            is_external    => 1,
            status         => 'poa_pending',
        },
        MTR1001019 => {
            account_type => "real",
            attributes   => {
                account_type    => "real",
                currency        => "USD",
                group           => "real\\p01_ts01\\financial\\vanuatu_std_usd",
                landing_company => "svg",
                leverage        => 300,
                market_type     => "financial",
            },
            creation_stamp => "2018-02-11 07:13:52.94334",
            currency       => "USD",
            loginid        => "MTR1001019",
            platform       => "mt5",
            is_virtual     => 0,
            is_external    => 1,
            status         => 'poa_pending',
        },
        MTR1001017 => {
            account_type => "real",
            attributes   => {
                account_type    => "real",
                currency        => "USD",
                group           => "real\\p01_ts01\\financial\\bvi_std_usd",
                landing_company => "svg",
                leverage        => 300,
                market_type     => "financial",
            },
            creation_stamp => "2018-02-01 07:13:52.94334",
            currency       => "USD",
            loginid        => "MTR1001017",
            platform       => "mt5",
            is_virtual     => 0,
            is_external    => 1,
            status         => 'poa_pending',
        },
    };
    $bom_user_mock->mock(
        'loginid_details',
        sub {
            $mock_logindetails;
        });

    $method = "mt5_withdrawal";
    $params = {
        language => 'EN',
        token    => $token,
        args     => {
            from_mt5  => 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\vanuatu_std-hr_usd'},
            to_binary => $new_client->loginid,
            amount    => 50,
        },
    };

    set_absolute_time(Date::Utility->new('2018-02-15')->epoch);
    $expired_documents = undef;
    my $account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $account_mock->mock('_fetch_mt5_lc', sub { return LandingCompany::Registry->by_name('vanuatu'); });

    # verified POA, false positive poa_failed, pass.
    $mock_logindetails->{MTR1001020}->{status} = 'poa_failed';
    $c->call_ok($method, $params)->has_no_error('withdrawal - verified POA, false positive poa_failed, pass');

    $user_client_mock->mock(
        'get_poa_status',
        sub {
            return 'pending';
        });

    $mock_logindetails->{MTR1001020}->{status} = 'poa_pending';
    # pending POA, within grace period, pass.
    $c->call_ok($method, $params)->has_no_error('withdrawal - pending POA, within grace period, pass');

    # pending POA, last day grace period, pass.
    $mock_logindetails->{MTR1001020}->{creation_stamp} = '2018-02-10 07:13:52.94334';
    $c->call_ok($method, $params)->has_no_error('withdrawal - pending POA, last day grace period, pass');

    # pending POA, post grace period, fail.
    $mock_logindetails->{MTR1001020}->{creation_stamp} = '2018-02-09 07:13:52.94334';
    $c->call_ok($method, $params)->has_error('Withdrawal failed.')
        ->error_message_like(qr/Proof of Address verification failed. Withdrawal operation suspended./);

    # pending POA, poa_failed, fail.
    $mock_logindetails->{MTR1001020}->{creation_stamp} = '2018-02-13 07:13:52.94334';
    $mock_logindetails->{MTR1001020}->{status}         = 'poa_failed';
    $c->call_ok($method, $params)->has_error('Withdrawal failed.')
        ->error_message_like(qr/Proof of Address verification failed. Withdrawal operation suspended./);

    # outdated POA, poa_outdated, still pass for low risk client.
    $user_client_mock->mock(
        'get_poa_status',
        sub {
            return 'expired';
        });
    $mock_logindetails->{MTR1001020}->{creation_stamp} = '2018-02-13 07:13:52.94334';
    $mock_logindetails->{MTR1001020}->{status}         = 'poa_outdated';
    $c->call_ok($method, $params)->has_no_error('withdrawal - expired POA, low risk client, pass');

    $user_client_mock->mock(
        'get_poa_status',
        sub {
            return 'pending';
        });
    $c->call_ok($method, $params)
        ->has_no_error('withdrawal - pending POA, mixed BVI and Vanuatu where vanuatu expired dont affect BVI within grace period, pass');

    $mock_logindetails->{MTR1001020}->{status} = 'poa_pending';
    # pending POA, mixed BVI and Vanuatu where vanuatu expired don't affect BVI within grace period, pass.
    $c->call_ok($method, $params)
        ->has_no_error('withdrawal - pending POA, mixed BVI and Vanuatu where vanuatu expired dont affect BVI within grace period, pass');

    # pending POA, multiple MT5 within grace period, pass
    $c->call_ok($method, $params)
        ->has_no_error('withdrawal - pending POA, mixed BVI and Vanuatu where vanuatu expired dont affect BVI within grace period, pass');

    # pending POA, selected MT5 within grace period but first account expired, fail
    $mock_logindetails->{MTR1001019}->{creation_stamp} = '2018-02-09 07:13:52.94334';
    $c->call_ok($method, $params)->has_error('Withdrawal failed.')
        ->error_message_like(qr/Proof of Address verification failed. Withdrawal operation suspended./);

    $mock_logindetails->{MTR1001019}->{creation_stamp} = Date::Utility->new()->date_yyyymmdd;
    $c->call_ok($method, $params)->has_no_error('withdrawal ok');

    # document expiration
    # outdated POA, poa_outdated, fail.
    $user_client_mock->mock(
        'get_poi_status',
        sub {
            return 'expired';
        });

    # enforcement depends on whether the client has mt5 regulated accounts or not
    ok $user->has_mt5_regulated_account(use_mt5_conf => 1), 'User has mt5 regulated';

    $expired_enforced  = undef;
    $outdated_poa      = 0;
    $expired_documents = 1;
    $c->call_ok($method, $params)->has_error('Withdrawal failed.')->error_message_like(qr/Your identity documents have expired./);
    ok $expired_enforced, 'Expired check was enforced';

    $expired_enforced  = undef;
    $outdated_poa      = 0;
    $expired_documents = 1;
    $c->call_ok($method, $params)->has_error('Withdrawal failed.')->error_message_like(qr/Your identity documents have expired./);
    ok $expired_enforced, 'Expired check was enforced';

    $expired_enforced  = undef;
    $outdated_poa      = 1;
    $expired_documents = 0;
    $c->call_ok($method, $params)->has_error('Withdrawal failed.')->error_message_like(qr/Your identity documents have expired./);
    ok $expired_enforced, 'Expired check was enforced';

    $expired_enforced  = undef;
    $expired_documents = 0;
    $outdated_poa      = 0;
    $c->call_ok($method, $params)->has_no_error('Withdrawal succeded.');
    ok $expired_enforced, 'Expired check was enforced';

    $manager_module->unmock('get_user', 'get_group');
    $user_client_mock->unmock('get_poi_status_jurisdiction', 'get_poa_status');
    $bom_user_mock->unmock('loginid_details');

    $expired_documents = undef;
    $outdated_poa      = undef;
};

subtest 'cannot deposit if status is migrated_without_position' => sub {
    my $client = BOM::User::Client->new({loginid => 'CR10000'});
    $client->user->update_loginid_status('MTR41000001', 'migrated_without_position');
    my $token = $m->create_token($client->loginid, 'test token');

    my $method = "mt5_deposit";
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            from_binary => $client->loginid,
            to_mt5      => 'MTR41000001',
            amount      => 10,
        },
    };

    $c->call_ok($method, $params)
        ->has_error('You cannot make a deposit because your MT5 account is disabled. Please contact our Customer Support team.')
        ->error_code_is('MT5DepositLocked');

    $client->user->update_loginid_status('MTR41000001', 'migrated_with_position');
    $c->call_ok($method, $params)->has_no_error('no error for mt5_deposit');

    $client->user->update_loginid_status('MTR41000001', undef);
};

$documents_mock->unmock_all;

# reset
BOM::Config::Runtime->instance->app_config->system->mt5->load_balance->demo->all->p01_ts02($p01_ts02_load);
BOM::Config::Runtime->instance->app_config->system->mt5->load_balance->demo->all->p01_ts03($p01_ts03_load);

done_testing();
