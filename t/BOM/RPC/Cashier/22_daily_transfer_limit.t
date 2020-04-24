use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Guard;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_user_transfer_limits);
use BOM::Test::Helper::ExchangeRates qw(populate_exchange_rates populate_exchange_rates_db);
use BOM::Test::Helper::Token qw(cleanup_redis_tokens);
use BOM::Test::RPC::Client;
use Test::BOM::RPC::Accounts;
use BOM::User;
use Date::Utility;
use BOM::Config::Runtime;
use BOM::Config::Chronicle;
use BOM::MT5::User::Async;

my $custom_rates = {
    BTC => 1,
    ETH => 1
};
populate_exchange_rates($custom_rates);
my $tmp_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => 'tmp@test.com'
});
populate_exchange_rates_db($tmp_client->db->dbic, $custom_rates);

cleanup_redis_tokens();

my $app_config = BOM::Config::Runtime->instance->app_config;
$app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

# We need to restore previous values when test is done
my %init_config_values = (
    'payments.transfer_between_accounts.limits.between_accounts' => $app_config->payments->transfer_between_accounts->limits->between_accounts,
    'payments.transfer_between_accounts.limits.MT5'              => $app_config->payments->transfer_between_accounts->limits->MT5,
);

scope_guard {
    for my $key (keys %init_config_values) {
        $app_config->set({$key => $init_config_values{$key}});
    }
};

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC::Transport::HTTP')->app->ua);

# setup clients

my $email = 'user2@test.com';
my $user  = BOM::User->create(
    email    => $email,
    password => 'test',
);

my $client_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => $email,
});
$client_usd->account('USD');
$user->add_client($client_usd);
$client_usd->payment_free_gift(
    currency => 'USD',
    amount   => 1000,
    remark   => 'free gift',
);
$client_usd->status->set('crs_tin_information', 'system', 'testing');

my $client_btc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => $email,
});
$client_btc->account('BTC');
$user->add_client($client_btc);

my $client_eth = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => $email,
});
$client_eth->account('ETH');
$user->add_client($client_eth);
$client_eth->payment_free_gift(
    currency => 'ETH',
    amount   => 1000,
    remark   => 'free gift',
);
$client_eth->status->set('crs_tin_information', 'system', 'testing');

my $token_usd = BOM::Platform::Token::API->new->create_token($client_usd->loginid, 'test');
my $token_btc = BOM::Platform::Token::API->new->create_token($client_btc->loginid, 'test');
my $token_eth = BOM::Platform::Token::API->new->create_token($client_eth->loginid, 'test');

subtest 'transfer between accounts' => sub {
    initialize_user_transfer_limits();
    $app_config->payments->transfer_between_accounts->limits->between_accounts(2);

    my $params = {
        token => $token_usd,
        args  => {
            account_from => $client_usd->loginid,
            account_to   => $client_btc->loginid,
            currency     => 'USD',
            amount       => 10,                     # will receive 9.9 BTC
        },
    };
    $c->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error('first transfer ok');

    $params = {
        token => $token_btc,
        args  => {
            account_from => $client_btc->loginid,
            account_to   => $client_usd->loginid,
            currency     => 'BTC',
            amount       => 9,
        },
    };

    $c->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error('second transfer ok');

    $c->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'error code for exceeded limit')
        ->error_message_like(qr/You can only perform up to 2 transfers a day/, 'error message for exceeded limit');

    $params = {
        token => $token_eth,
        args  => {
            account_from => $client_eth->loginid,
            account_to   => $client_usd->loginid,
            currency     => 'ETH',
            amount       => 10,
        },
    };

    $c->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'limit applies to different account of same user')
        ->error_message_like(qr/You can only perform up to 2 transfers a day/, 'error message');

    $app_config->payments->transfer_between_accounts->limits->between_accounts(3);
    $c->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error('third transfer ok with updated limit');

};

subtest 'mt5' => sub {

    @BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');
    my $mock_account = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $mock_account->mock(
        _is_financial_assessment_complete => sub { return 1 },
        _throttle                         => sub { return 0 });
    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->mock(
        fully_authenticated => sub { return 1 },
        has_valid_documents => sub { return 1 });

    my $mock_fees = Test::MockModule->new('BOM::Config::CurrencyConfig');
    $mock_fees->mock(transfer_between_accounts_fees => sub { return {ETH => {USD => 0}, USD => {ETH => 0}} });

    my %DETAILS = %Test::BOM::RPC::Accounts::ACCOUNT_DETAILS;

    my $params = {
        token => $token_usd,
        args  => {
            account_type     => 'financial',
            mt5_account_type => 'standard',
            investPassword   => $DETAILS{investPassword},
            mainPassword     => $DETAILS{password}{main},
        },
    };
    my $login_std = $c->call_ok('mt5_new_account', $params)->has_no_system_error->has_no_error('create standard mt5 account')->result->{login};
    $params->{args}{mt5_account_type} = 'advanced';
    my $login_adv = $c->call_ok('mt5_new_account', $params)->has_no_system_error->has_no_error('create advanced mt5 account')->result->{login};

    subtest 'mt5_deposit' => sub {
        initialize_user_transfer_limits();
        $app_config->payments->transfer_between_accounts->limits->MT5(2);

        $params->{args} = {
            amount      => 180,
            from_binary => $client_usd->loginid,
            to_mt5      => $login_std,
        };
        $c->call_ok('mt5_deposit', $params)->has_no_system_error->has_no_error('first mt5 deposit');

        $params = {
            token => $token_eth,
            args  => {
                amount      => 180,
                from_binary => $client_eth->loginid,
                to_mt5      => $login_adv,
            },
        };
        $c->call_ok('mt5_deposit', $params)->has_no_system_error->has_no_error('second mt5 deposit');

        $params = {
            token => $token_usd,
            args  => {
                amount      => 180,
                from_binary => $client_usd->loginid,
                to_mt5      => $login_adv,
            },
        };

        $c->call_ok('mt5_deposit', $params)
            ->has_no_system_error->has_error->error_code_is('MT5DepositError', 'limit applies to different account of same user')
            ->error_message_like(qr/You can only perform up to 2 transfers a day/, 'error message');

        $app_config->payments->transfer_between_accounts->limits->MT5(3);
        $c->call_ok('mt5_deposit', $params)->has_no_system_error->has_no_error('third transfer ok with updated limit');
    };

    subtest 'mt5_withdrawal' => sub {
        initialize_user_transfer_limits();
        $app_config->payments->transfer_between_accounts->limits->MT5(2);

        $params->{args} = {
            amount    => 150,
            to_binary => $client_usd->loginid,
            from_mt5  => $login_std,
        };
        $c->call_ok('mt5_withdrawal', $params)->has_no_system_error->has_no_error('first mt5 withdrawal');

        $params = {
            token => $token_eth,
            args  => {
                amount    => 150,
                to_binary => $client_eth->loginid,
                from_mt5  => $login_adv,
            },
        };
        $c->call_ok('mt5_withdrawal', $params)->has_no_system_error->has_no_error('second mt5 withdrawal');

        $params = {
            token => $token_usd,
            args  => {
                amount    => 150,
                to_binary => $client_usd->loginid,
                from_mt5  => $login_adv,
            },
        };

        $c->call_ok('mt5_withdrawal', $params)
            ->has_no_system_error->has_error->error_code_is('MT5WithdrawalError', 'limit applies to different account of same user')
            ->error_message_like(qr/You can only perform up to 2 transfers a day/, 'error message');

        $app_config->payments->transfer_between_accounts->limits->MT5(3);
        $c->call_ok('mt5_withdrawal', $params)->has_no_system_error->has_no_error('third transfer ok with updated limit');
    };

    subtest 'transfer_between_accounts to mt5' => sub {
        initialize_user_transfer_limits();
        $app_config->payments->transfer_between_accounts->limits->MT5(2);

        $params->{args} = {
            amount       => 180,
            currency     => 'USD',
            account_from => $client_usd->loginid,
            account_to   => $login_std,
        };
        $c->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error('first mt5 deposit');

        $params = {
            token => $token_eth,
            args  => {
                amount       => 180,
                currency     => 'ETH',
                account_from => $client_eth->loginid,
                account_to   => $login_adv,
            },
        };
        $c->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error('second mt5 deposit');

        $params = {
            token => $token_usd,
            args  => {
                amount       => 180,
                currency     => 'USD',
                account_from => $client_usd->loginid,
                account_to   => $login_adv,
            },
        };

        $c->call_ok('transfer_between_accounts', $params)
            ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'limit applies to different account of same user')
            ->error_message_like(qr/You can only perform up to 2 transfers a day/, 'error message');

        $app_config->payments->transfer_between_accounts->limits->MT5(3);
        $c->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error('third transfer ok with updated limit');
    };

    subtest 'transfer_between_accounts from mt5' => sub {
        initialize_user_transfer_limits();
        $app_config->payments->transfer_between_accounts->limits->MT5(2);

        $params->{args} = {
            amount       => 150,
            currency     => 'USD',
            account_to   => $client_usd->loginid,
            account_from => $login_std,
        };
        $c->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error('first mt5 withdrawal');

        $params = {
            token => $token_eth,
            args  => {
                amount       => 150,
                currency     => 'USD',
                account_to   => $client_eth->loginid,
                account_from => $login_adv,
            },
        };
        $c->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error('second mt5 withdrawal');

        $params = {
            token => $token_usd,
            args  => {
                amount       => 150,
                currency     => 'USD',
                account_to   => $client_usd->loginid,
                account_from => $login_adv,
            },
        };

        $c->call_ok('transfer_between_accounts', $params)
            ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'limit applies to different account of same user')
            ->error_message_like(qr/You can only perform up to 2 transfers a day/, 'error message');

        $app_config->payments->transfer_between_accounts->limits->MT5(3);
        $c->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error('third transfer ok with updated limit');
    };
};

done_testing;
