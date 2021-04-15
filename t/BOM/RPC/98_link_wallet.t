use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::MockModule;
use Test::BOM::RPC::QueueClient;

use BOM::Platform::Token::API;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::RPC;
use BOM::RPC::Registry;
use BOM::Platform::Token::API;
use BOM::Test::Script::DevExperts;

use Test::BOM::RPC::Accounts;

@BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

# Init DB
my $email    = 'test@binary.com';
my $password = 'Abcd1234';
my $hash_pwd = BOM::User::Password::hashpw($password);

my $vr_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});
$vr_client->set_default_account('USD');
$vr_client->email($email);
$vr_client->save;

my $vr_wallet = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRDW',
});
$vr_wallet->set_default_account('USD');
$vr_wallet->email($email);
$vr_wallet->save;

my $user = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);
$user->add_client($vr_client);
$user->add_client($vr_wallet);

my $c = Test::BOM::RPC::QueueClient->new();

my $m     = BOM::Platform::Token::API->new;
my $token = $m->create_token($vr_client->loginid, 'test token');

# MT5 test accounts
my %ACCOUNTS = %Test::BOM::RPC::Accounts::MT5_ACCOUNTS;
my %DETAILS  = %Test::BOM::RPC::Accounts::ACCOUNT_DETAILS;

BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(0);

my $method = 'link_wallet';
subtest 'link_wallet' => sub {
    my $params->{token} = $token;

    $params->{args}->{wallet_id} = $vr_wallet->loginid;
    $params->{args}->{client_id} = $vr_client->loginid;

    is($c->tcall($method, $params)->{status}, 1, 'can bind trading and wallet account');

    subtest 'bind mt5 to wallet account' => sub {
        $vr_client->set_default_account('USD');

        my $params = {
            token => $token,
            args  => {
                account_type     => 'demo',
                mt5_account_type => 'financial',
                email            => $email,
                name             => $DETAILS{name},
                mainPassword     => $DETAILS{password}{main},
                leverage         => 100,
            },
        };

        BOM::RPC::v3::MT5::Account::reset_throttler($vr_client->loginid);
        my $result = $c->tcall('mt5_new_account', $params);
        is $result->{account_type}, 'demo';
        is $result->{login},        'MTD' . $ACCOUNTS{'demo\p01_ts01\financial\svg_std_usd'};

        $params->{args}->{wallet_id} = $vr_wallet->loginid;
        $params->{args}->{client_id} = $result->{login};

        is($c->tcall($method, $params)->{status}, 1, 'can bind mt5 and wallet account');
    };

    subtest 'bind dxtrade to wallet account' => sub {
        my $params = {
            token => $token,
            args  => {
                platform     => 'dxtrade',
                account_type => 'demo',
                market_type  => 'financial',
                password     => 'test',
                currency     => 'USD',
            },
        };

        my $result = $c->tcall('trading_platform_new_account', $params);

        $params->{args}->{wallet_id} = $vr_wallet->loginid;
        $params->{args}->{client_id} = $result->{account_id};

        is($c->tcall($method, $params)->{status}, 1, 'can bind dxtrade and wallet account');
    };

    subtest 'cannot rebind to another wallet' => sub {
        my $vr_wallet_2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'VRDW',
        });
        $user->add_client($vr_wallet_2);

        $params->{args}->{wallet_id} = $vr_wallet_2->loginid;
        $params->{args}->{client_id} = $vr_client->loginid;

        is($c->tcall($method, $params)->{error}{code}, 'CannotChangeWallet', 'cannot rebind trading account to another wallet account');
    };

    subtest 'cannot bind wallet if currency is not the same' => sub {
        my $email = 'test2@binary.com';
        my $user  = BOM::User->create(
            email    => $email,
            password => $hash_pwd
        );

        my $vr_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'VRTC',
        });
        $vr_client->email($email);
        $vr_client->save;
        $user->add_client($vr_client);

        my $eur_wallet = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'VRDW',
        });
        $eur_wallet->set_default_account('EUR');
        $eur_wallet->email($email);
        $eur_wallet->save;
        $user->add_client($eur_wallet);

        $token = $m->create_token($vr_client->loginid, 'test token');
        $params->{token} = $token;

        $params->{args}->{wallet_id} = $eur_wallet->loginid;
        $params->{args}->{client_id} = $vr_client->loginid;

        is($c->tcall($method, $params)->{error}{code}, 'CurrencyMismatch', 'cannot bind trading account to a wallet of different currency');
    };

    subtest 'invalid loginids' => sub {
        $params->{args}->{wallet_id} = 'VRDW1001';
        is($c->tcall($method, $params)->{error}{code}, 'InvalidWalletAccount', 'correct error code for invalid wallet loginid');

        my $vr_wallet = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'VRDW',
        });
        $user->add_client($vr_wallet);

        $token = $m->create_token($vr_wallet->loginid, 'test token');
        $params->{token} = $token;

        $params->{args}->{wallet_id} = $vr_wallet->loginid;
        $params->{args}->{client_id} = 'VRTC9000234';
        is($c->tcall($method, $params)->{error}{code}, 'InvalidTradingAccount', 'correct error code for invalid client loginid');

        $params->{args}->{client_id} = 'MTD90000';
        is($c->tcall($method, $params)->{error}{code}, 'InvalidMT5Account', 'correct error code for invalid mt5 loginid');

        $params->{args}->{client_id} = 'DXR10001';
        is($c->tcall($method, $params)->{error}{code}, 'DXInvalidAccount', 'correct error code for invalid dxtrader loginid');
    }
};

BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(1);

done_testing();
