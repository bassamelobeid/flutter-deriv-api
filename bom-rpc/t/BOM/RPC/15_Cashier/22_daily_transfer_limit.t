use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Guard;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis    qw(initialize_user_transfer_limits);
use BOM::Test::Helper::ExchangeRates           qw(populate_exchange_rates populate_exchange_rates_db);
use BOM::Test::Helper::Token                   qw(cleanup_redis_tokens);
use BOM::Test::RPC::QueueClient;
use Test::BOM::RPC::Accounts;
use BOM::User;
use Date::Utility;
use BOM::Config::Runtime;
use BOM::Config::Chronicle;
use BOM::MT5::User::Async;

my $redis = BOM::Config::Redis::redis_exchangerates_write();

my $documents_mock = Test::MockModule->new('BOM::User::Client::AuthenticationDocuments');
my $has_valid_documents;
$documents_mock->mock(
    'valid',
    sub {
        my ($self) = @_;

        return $has_valid_documents if defined $has_valid_documents;
        return $documents_mock->original('valid')->(@_);
    });

sub _offer_to_clients {
    my $from_currency = shift;
    my $to_currency   = shift // 'USD';

    $redis->hmset("exchange_rates::${from_currency}_${to_currency}", offer_to_clients => 1);
}
_offer_to_clients($_) for qw/BTC USD ETH UST/;

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

my $c = BOM::Test::RPC::QueueClient->new();

# setup clients

my $email = 'user2@test.com';
my $user  = BOM::User->create(
    email    => $email,
    password => 'test',
);

my $client_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code            => 'CR',
    email                  => $email,
    account_opening_reason => 'Speculative',
    binary_user_id         => $user->id,
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
    broker_code    => 'CR',
    email          => $email,
    binary_user_id => $user->id,
});
$client_btc->account('BTC');
$user->add_client($client_btc);

my $client_eth = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    email          => $email,
    binary_user_id => $user->id,
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
        ->has_no_system_error->has_error->error_code_is('MaximumTransfers', 'error code for exceeded limit')
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
        ->has_no_system_error->has_error->error_code_is('MaximumTransfers', 'limit applies to different account of same user')
        ->error_message_like(qr/You can only perform up to 2 transfers a day/, 'error message');

    $app_config->payments->transfer_between_accounts->limits->between_accounts(3);
    $c->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error('third transfer ok with updated limit');

};

subtest 'mt5' => sub {

    @BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');
    my $mock_account = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $mock_account->mock(_is_financial_assessment_complete => sub { return 1 });
    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->mock(fully_authenticated         => sub { return 1 });
    $mock_client->mock(get_poi_status_jurisdiction => sub { return 'verified' });
    $mock_client->mock(get_poa_status              => sub { return 'verified' });
    $has_valid_documents = 1;
    $client_usd->tax_residence('us');
    $client_usd->tax_identification_number('123');
    $client_usd->save;

    my $mock_fees = Test::MockModule->new('BOM::Config::CurrencyConfig');
    $mock_fees->mock(transfer_between_accounts_fees => sub { return {ETH => {USD => 0}, USD => {ETH => 0}} });

    my %DETAILS = %Test::BOM::RPC::Accounts::ACCOUNT_DETAILS;

    my $params = {
        token => $token_usd,
        args  => {
            account_type     => 'financial',
            mt5_account_type => 'financial',
            investPassword   => $DETAILS{investPassword},
            mainPassword     => $DETAILS{password}{main},
        },
    };
    $client_usd->user->update_trading_password($DETAILS{password}{main});
    my $login_std = $c->call_ok('mt5_new_account', $params)->has_no_system_error->has_no_error('create financial mt5 account')->result->{login};
    $params->{args}{mt5_account_type} = 'financial_stp';
    my $login_adv = $c->call_ok('mt5_new_account', $params)->has_no_system_error->has_no_error('create financial_stp mt5 account')->result->{login};

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
            ->has_no_system_error->has_error->error_code_is('MaximumTransfers', 'limit applies to different account of same user')
            ->error_message_like(qr/You can only perform up to 2 transfers a day/, 'error message');

        $app_config->payments->transfer_between_accounts->limits->MT5(3);
        $c->call_ok('mt5_deposit', $params)->has_no_system_error->has_no_error('third transfer ok with updated limit');
    };

    subtest 'mt5_deposit with total limit' => sub {
        initialize_user_transfer_limits();
        $app_config->payments->transfer_between_accounts->daily_cumulative_limit->enable(1);
        $app_config->payments->transfer_between_accounts->daily_cumulative_limit->MT5(500);
        $app_config->set({
            'payments.transfer_between_accounts.minimum.default'               => 1,
            'payments.transfer_between_accounts.maximum.default'               => 2500,
            'payments.transfer_between_accounts.daily_cumulative_limit.enable' => 1,
            'payments.transfer_between_accounts.daily_cumulative_limit.MT5'    => 500,
        });
        $params->{args} = {
            amount      => 180,
            from_binary => $client_usd->loginid,
            to_mt5      => $login_std,
        };
        $params->{token} = $token_usd;
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
            ->has_no_system_error->has_error->error_code_is('MaximumAmountTransfers', 'limit applies to different account of same user')
            ->error_message_like(qr/The maximum amount of transfers is/, 'per day. Please try again tomorrow.');

        $app_config->set({
            'payments.transfer_between_accounts.daily_cumulative_limit.enable' => 1,
            'payments.transfer_between_accounts.daily_cumulative_limit.MT5'    => 600,
        });
        $app_config->payments->transfer_between_accounts->daily_cumulative_limit->MT5(600);
        $c->call_ok('mt5_deposit', $params)->has_no_system_error->has_no_error('third transfer ok with updated total limit');
    };

    subtest 'mt5_withdrawal' => sub {
        initialize_user_transfer_limits();
        $app_config->payments->transfer_between_accounts->daily_cumulative_limit->enable(0);
        $app_config->set({
            'payments.transfer_between_accounts.daily_cumulative_limit.enable' => 0,
            'payments.transfer_between_accounts.daily_cumulative_limit.MT5'    => 600,
        });
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
            ->has_no_system_error->has_error->error_code_is('MaximumTransfers', 'limit applies to different account of same user')
            ->error_message_like(qr/You can only perform up to 2 transfers a day/, 'error message');

        $app_config->payments->transfer_between_accounts->limits->MT5(3);
        $c->call_ok('mt5_withdrawal', $params)->has_no_system_error->has_no_error('third transfer ok with updated limit');
    };

    subtest 'mt5_withdrawal with total limits' => sub {
        initialize_user_transfer_limits();
        $app_config->payments->transfer_between_accounts->daily_cumulative_limit->enable(1);
        $app_config->payments->transfer_between_accounts->daily_cumulative_limit->MT5(400);
        $app_config->set({
            'payments.transfer_between_accounts.daily_cumulative_limit.enable' => 1,
            'payments.transfer_between_accounts.daily_cumulative_limit.MT5'    => 400,
        });
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
            ->has_no_system_error->has_error->error_code_is('MaximumAmountTransfers', 'limit applies to different account of same user')
            ->error_message_like(qr/The maximum amount of transfers is/, 'per day. Please try again tomorrow.');

        $app_config->payments->transfer_between_accounts->daily_cumulative_limit->MT5(500);
        $app_config->set({
            'payments.transfer_between_accounts.daily_cumulative_limit.enable' => 1,
            'payments.transfer_between_accounts.daily_cumulative_limit.MT5'    => 500,
        });
        $c->call_ok('mt5_withdrawal', $params)->has_no_system_error->has_no_error('third transfer ok with updated total limit');
    };

    subtest 'transfer_between_accounts to mt5' => sub {
        initialize_user_transfer_limits();
        $app_config->set({
            'payments.transfer_between_accounts.daily_cumulative_limit.enable' => 0,
            'payments.transfer_between_accounts.daily_cumulative_limit.MT5'    => 500,
        });
        $app_config->payments->transfer_between_accounts->daily_cumulative_limit->enable(0);
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
            ->has_no_system_error->has_error->error_code_is('MaximumTransfers', 'limit applies to different account of same user')
            ->error_message_like(qr/You can only perform up to 2 transfers a day/, 'error message');

        $app_config->payments->transfer_between_accounts->limits->MT5(3);
        $c->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error('third transfer ok with updated limit');
    };

    subtest 'transfer_between_accounts to mt5 with total limit' => sub {
        initialize_user_transfer_limits();
        $app_config->payments->transfer_between_accounts->daily_cumulative_limit->enable(1);
        $app_config->payments->transfer_between_accounts->daily_cumulative_limit->MT5(500);
        $app_config->set({
            'payments.transfer_between_accounts.daily_cumulative_limit.enable' => 1,
            'payments.transfer_between_accounts.daily_cumulative_limit.MT5'    => 500,
        });
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
            ->has_no_system_error->has_error->error_code_is('MaximumAmountTransfers', 'limit applies to different account of same user')
            ->error_message_like(qr/The maximum amount of transfers is/, 'per day. Please try again tomorrow.');
        $app_config->set({
            'payments.transfer_between_accounts.daily_cumulative_limit.enable' => 1,
            'payments.transfer_between_accounts.daily_cumulative_limit.MT5'    => 1000,
        });
        $app_config->payments->transfer_between_accounts->daily_cumulative_limit->MT5(1000);
        $c->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error('third transfer ok with updated limit');
    };

    subtest 'transfer_between_accounts from mt5' => sub {
        initialize_user_transfer_limits();
        $app_config->payments->transfer_between_accounts->daily_cumulative_limit->enable(0);
        $app_config->payments->transfer_between_accounts->limits->MT5(2);
        $app_config->set({
            'payments.transfer_between_accounts.daily_cumulative_limit.enable' => 0,
            'payments.transfer_between_accounts.daily_cumulative_limit.MT5'    => 1000,
        });
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
            ->has_no_system_error->has_error->error_code_is('MaximumTransfers', 'limit applies to different account of same user')
            ->error_message_like(qr/You can only perform up to 2 transfers a day/, 'error message');

        $app_config->payments->transfer_between_accounts->limits->MT5(3);
        $c->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error('third transfer ok with updated limit');
    };

    subtest 'transfer_between_accounts from mt5' => sub {
        initialize_user_transfer_limits();
        $app_config->payments->transfer_between_accounts->daily_cumulative_limit->enable(1);
        $app_config->payments->transfer_between_accounts->daily_cumulative_limit->MT5(400);
        $app_config->set({
            'payments.transfer_between_accounts.daily_cumulative_limit.enable' => 1,
            'payments.transfer_between_accounts.daily_cumulative_limit.MT5'    => 400,
        });
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
            ->has_no_system_error->has_error->error_code_is('MaximumAmountTransfers', 'limit applies to different account of same user')
            ->error_message_like(qr/The maximum amount of transfers is/, 'per day. Please try again tomorrow.');

        $app_config->payments->transfer_between_accounts->daily_cumulative_limit->MT5(1000);
        $app_config->set({
            'payments.transfer_between_accounts.daily_cumulative_limit.enable' => 1,
            'payments.transfer_between_accounts.daily_cumulative_limit.MT5'    => 1000,
        });
        $c->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error('third transfer ok with updated limit');
    };
};

subtest 'transfer between accounts with daily_cumulative_limit enabled' => sub {
    initialize_user_transfer_limits();
    $app_config->payments->transfer_between_accounts->daily_cumulative_limit->enable(1);
    $app_config->payments->transfer_between_accounts->daily_cumulative_limit->between_accounts(20);
    $app_config->set({
        'payments.transfer_between_accounts.minimum.default'                         => 1,
        'payments.transfer_between_accounts.maximum.default'                         => 2500,
        'payments.transfer_between_accounts.daily_cumulative_limit.enable'           => 1,
        'payments.transfer_between_accounts.daily_cumulative_limit.between_accounts' => 20,
    });

    my $params = {
        token => $token_usd,
        args  => {
            account_from => $client_usd->loginid,
            account_to   => $client_btc->loginid,
            currency     => 'USD',
            amount       => 10,
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

    my $res = $c->call_ok('transfer_between_accounts', $params);
    $res->has_no_system_error->has_error->error_code_is('MaximumAmountTransfers', 'error code for exceeded limit')
        ->error_message_like(qr/The maximum amount of transfers is /, 'per day. Please try again tomorrow.');

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
        ->has_no_system_error->has_error->error_code_is('MaximumAmountTransfers', 'limit applies to different account of same user')
        ->error_message_like(qr/The maximum amount of transfers is /, 'per day. Please try again tomorrow.');

    $app_config->payments->transfer_between_accounts->limits->between_accounts(30);
    $app_config->set({
        'payments.transfer_between_accounts.minimum.default'                         => 1,
        'payments.transfer_between_accounts.maximum.default'                         => 2500,
        'payments.transfer_between_accounts.daily_cumulative_limit.enable'           => 1,
        'payments.transfer_between_accounts.daily_cumulative_limit.between_accounts' => 30,
    });
    $c->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error('third transfer ok with updated total limit');
    $app_config->payments->transfer_between_accounts->daily_cumulative_limit->enable(0);
};

$documents_mock->unmock_all;

done_testing;
