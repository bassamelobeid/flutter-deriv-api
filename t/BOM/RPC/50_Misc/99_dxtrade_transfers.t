use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Test::Deep;
use Test::MockModule;
use BOM::Test::Helper::ExchangeRates           qw(populate_exchange_rates populate_exchange_rates_db);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Script::DevExperts;
use BOM::Platform::Token::API;
use BOM::Test::RPC::QueueClient;
use BOM::Test::Helper::Client;
use BOM::Config::Runtime;

populate_exchange_rates({BTC => 2000});

BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(0);
BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->demo(0);
BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->real(0);
BOM::Config::Runtime->instance->app_config->system->suspend->wallets(1);
BOM::Config::Runtime->instance->app_config->system->dxtrade->enable_all_market_type->demo(1);
BOM::Config::Runtime->instance->app_config->system->dxtrade->enable_all_market_type->real(1);

my $c = BOM::Test::RPC::QueueClient->new();

my $client1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
my $client2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
my $user    = BOM::User->create(
    email    => 'dxtransfers@test.com',
    password => 'test'
);
map { $user->add_client($_), $_->account('USD') } ($client1, $client2);
my $token1 = BOM::Platform::Token::API->new->create_token($client1->loginid, 'test token');
my $token2 = BOM::Platform::Token::API->new->create_token($client2->loginid, 'test token');

my $client_btc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
$client_btc->account('BTC');
$user->add_client($client_btc);
my $token_btc = BOM::Platform::Token::API->new->create_token($client_btc->loginid, 'test token');

my $client3 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
BOM::User->create(
    email    => 'transfers2@test.com',
    password => 'test'
)->add_client($client3);
$client3->account('USD');
my $token3 = BOM::Platform::Token::API->new->create_token($client3->loginid, 'test token');

my $currency_config_mock = Test::MockModule->new('BOM::Config::CurrencyConfig');
my $is_experimental_currency;
$currency_config_mock->mock(
    'is_experimental_currency',
    sub {
        return $is_experimental_currency;
    });

my $is_account_merging;
my $account_under_merging_mock = Test::MockModule->new('BOM::RPC::v3::Trading');
$account_under_merging_mock->mock(
    'check_account_is_merging',
    sub {
        return $is_account_merging;
    });

my ($dx_demo, $dx_real);

subtest 'platform deposit and withdrawal' => sub {

    my $params = {language => 'EN'};

    $c->call_ok('trading_platform_deposit',    $params)->has_no_system_error->has_error->error_code_is('InvalidToken', 'must be logged in');
    $c->call_ok('trading_platform_withdrawal', $params)->has_no_system_error->has_error->error_code_is('InvalidToken', 'must be logged in');

    $params->{token} = $token1;
    $params->{args}  = {
        platform     => 'dxtrade',
        account_type => 'demo',
        market_type  => 'all',
        password     => 'Abcd1234',
        currency     => 'USD',
    };
    $dx_demo = $c->call_ok('trading_platform_new_account', $params)->result;

    $params->{args} = {
        platform     => 'dxtrade',
        account_type => 'real',
        market_type  => 'all',
        password     => 'Abcd1234',
        currency     => 'USD',
    };

    $dx_real = $c->call_ok('trading_platform_new_account', $params)->result;

    $params->{args} = {
        platform   => 'dxtrade',
        to_account => $dx_demo->{account_id},
    };

    $c->call_ok('trading_platform_deposit', $params)
        ->has_no_system_error->has_error->error_code_is('DXDemoTopupBalance', 'expected error for top up virtual');

    $params->{args}{from_account} = 'xyz';
    $params->{args}{amount}       = -1;
    $c->call_ok('trading_platform_deposit', $params)
        ->has_no_system_error->has_error->error_code_is('DXDemoTopupBalance', 'from_account and demo ignored for demo');

    delete $params->{args}{amount};
    $params->{args}{to_account} = $dx_real->{account_id};

    $c->call_ok('trading_platform_deposit', $params)
        ->has_no_system_error->has_error->error_code_is('PlatformTransferRealParams', 'from_account and amount needed for real account');

    $params->{args}{from_account} = $client2->loginid;
    $params->{args}{amount}       = 50;

    $c->call_ok('trading_platform_deposit', $params)
        ->has_no_system_error->has_error->error_code_is('PlatformTransferOauthTokenRequired', 'non oauth token not allowed')
        ->error_message_is('This request must be made using a connection authorized by the Deriv account involved in the transfer.');

    $params->{args}{from_account} = $client1->loginid;

    $is_experimental_currency = 1;
    $c->call_ok('trading_platform_deposit', $params)
        ->has_no_system_error->has_error->error_code_is('CurrencyTypeNotAllowed', 'Experimental currency not allowed')
        ->error_message_is('This currency is temporarily suspended. Please select another currency to proceed.');

    $is_experimental_currency = 0;
    BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->dxtrade(1);
    $client1->user->daily_transfer_incr_count('dxtrade', $client1->user->id);
    $c->call_ok('trading_platform_deposit', $params)->has_no_system_error->has_error->error_code_is('MaximumTransfers', 'Daily transfer limit hit')
        ->error_message_is('You can only perform up to 1 transfers a day. Please try again tomorrow.');

    BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->dxtrade(100);

    $c->call_ok('trading_platform_deposit', $params)->has_no_system_error->has_error->error_code_is('PlatformTransferError', 'Insufficient balance');

    my $app_config = BOM::Config::Runtime->instance->app_config();
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());
    $app_config->set({'payments.transfer_between_accounts.minimum.dxtrade' => '{"default":{"currency":"USD","amount":60}}'});

    $c->call_ok('trading_platform_deposit', $params)->has_no_system_error->has_error->error_code_is('InvalidMinAmount', 'Invalid min amount hit')
        ->error_message_is('The minimum amount for transfers is 60.00 USD. Please adjust your amount.');

    $app_config->set({'payments.transfer_between_accounts.minimum.dxtrade' => '{"default":{"currency":"USD","amount":1}}'});
    $app_config->set({'payments.transfer_between_accounts.maximum.dxtrade' => '{"default":{"currency":"USD","amount":5}}'});
    $c->call_ok('trading_platform_deposit', $params)->has_no_system_error->has_error->error_code_is('InvalidMaxAmount', 'Invalid max amount hit')
        ->error_message_is('The maximum amount for deposits is 5.00 USD. Please adjust your amount.');

    $app_config->set({'payments.transfer_between_accounts.maximum.dxtrade' => '{"default":{"currency":"USD","amount":50}}'});
    BOM::Test::Helper::Client::top_up($client1, 'USD', 50);

    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(1);

    $c->call_ok('trading_platform_deposit', $params)
        ->has_no_system_error->has_error->error_code_is('DXSuspended', 'cannot deposit when dxtrade suspended');

    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(0);

    # payment agent restriction
    my $mock_pa = Test::MockObject->new;
    $mock_pa->mock(status       => sub { 'authorized' });
    $mock_pa->mock(tier_details => sub { {} });

    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine(get_payment_agent => $mock_pa);

    $c->call_ok('trading_platform_deposit', $params)
        ->has_no_system_error->has_error->error_code_is('ServiceNotAllowedForPA', 'Payment agents cannot make DXTrade deposits.');

    $mock_client->unmock_all;

    # successful transfer
    my $res = $c->call_ok('trading_platform_deposit', $params)->has_no_system_error->has_no_error->result;
    delete $res->{stash};
    cmp_deeply($res, {transaction_id => re('\d+')}, 'deposit transaction id returned');
    cmp_ok $client1->account->balance, '==', 0, 'client balance decreased';

    $params->{args} = {
        platform     => 'dxtrade',
        from_account => $dx_real->{account_id},
        to_account   => $client1->loginid,
        amount       => 50,
    };

    BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->dxtrade(2);
    $c->call_ok('trading_platform_withdrawal', $params)
        ->has_no_system_error->has_error->error_code_is('MaximumTransfers', 'Daily transfer limit hit')
        ->error_message_is('You can only perform up to 2 transfers a day. Please try again tomorrow.');

    BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->dxtrade(100);
    $app_config->set({'payments.transfer_between_accounts.minimum.dxtrade' => '{"default":{"currency":"USD","amount":60}}'});
    $c->call_ok('trading_platform_withdrawal', $params)->has_no_system_error->has_error->error_code_is('InvalidMinAmount', 'Invalid min amount hit')
        ->error_message_is('The minimum amount for transfers is 60.00 USD. Please adjust your amount.');

    $app_config->set({'payments.transfer_between_accounts.minimum.dxtrade' => '{"default":{"currency":"USD","amount":1}}'});
    $app_config->set({'payments.transfer_between_accounts.maximum.dxtrade' => '{"default":{"currency":"USD","amount":5}}'});
    $c->call_ok('trading_platform_withdrawal', $params)->has_no_system_error->has_error->error_code_is('InvalidMaxAmount', 'Invalid max amount hit')
        ->error_message_is('The maximum amount for deposits is 5.00 USD. Please adjust your amount.');

    $app_config->set({'payments.transfer_between_accounts.maximum.dxtrade' => '{"default":{"currency":"USD","amount":1000}}'});

    $res = $c->call_ok('trading_platform_withdrawal', $params)->has_no_system_error->has_no_error->result;
    delete $res->{stash};
    cmp_deeply($res, {transaction_id => re('\d+')}, 'withdrawal transaction id returned');
    cmp_ok $client1->account->balance, '==', 50, 'client balance increased';

    BOM::Test::Helper::Client::top_up($client2, 'USD', 50);
    BOM::Test::Helper::Client::top_up($client3, 'USD', 50);

    $params->{token_type} = 'oauth_token';
    $params->{args}       = {
        platform     => 'dxtrade',
        from_account => $client2->loginid,
        to_account   => $dx_real->{account_id},
        amount       => 50,
        currency     => 'USD',
    };
    $c->call_ok('trading_platform_deposit', $params)->has_no_system_error->has_no_error('sibling client can transfer');

    $params->{args}{from_account} = $client3->loginid;
    $c->call_ok('trading_platform_deposit', $params)
        ->has_no_system_error->has_error->error_code_is('PlatformTransferAccountInvalid', 'Non sibling cannot transfer');

    $params->{token} = $token3;
    $c->call_ok('trading_platform_deposit', $params)
        ->has_no_system_error->has_error->error_code_is('DXInvalidAccount', 'Non sibling cannot transfer when logged in');

    $params->{args}{from_account} = $client3->loginid;
    $c->call_ok('trading_platform_deposit', $params)
        ->has_no_system_error->has_error->error_code_is('DXInvalidAccount', 'Non sibling cannot transfer from own account');
};

subtest 'transfer between accounts' => sub {
    my $params = {
        language => 'EN',
        token    => $token1,
        args     => {
            accounts => 'all',
        }};

    my $res    = $c->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error->result;
    my @logins = map { $_->{loginid} } $res->{accounts}->@*;
    cmp_deeply [@logins], bag($client1->loginid, $client2->loginid, $client_btc->loginid, $dx_real->{account_id}),
        'all real and demo accounts returned';

    $params->{args} = {
        account_from => $client2->loginid,
        account_to   => $dx_real->{account_id},
        amount       => 50,
        currency     => 'EUR',
    };

    $c->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_error->error_code_is('PlatformTransferOauthTokenRequired', 'non oauth token not allowed');

    $params->{args}{account_from} = $client1->loginid;

    subtest 'Validations from rules engine' => sub {
        $c->call_ok('transfer_between_accounts', $params)
            ->has_no_system_error->has_error->error_code_is('CurrencyShouldMatch', 'Currency should match from account currency');

        $params->{args}{currency} = 'USD';

        $is_experimental_currency = 1;
        $c->call_ok('transfer_between_accounts', $params)
            ->has_no_system_error->has_error->error_code_is('CurrencyTypeNotAllowed', 'Experimental currency not allowed')
            ->error_message_is('This currency is temporarily suspended. Please select another currency to proceed.');

        $is_experimental_currency = 0;

        BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->daily_cumulative_limit->enable(0);
        BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->dxtrade(1);
        $client1->user->daily_transfer_incr_count('dxtrade', $client1->user->id);

        $c->call_ok('transfer_between_accounts', $params)
            ->has_no_system_error->has_error->error_code_is('MaximumTransfers', 'Daily transfer limit hit')
            ->error_message_is('You can only perform up to 1 transfers a day. Please try again tomorrow.');

        BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->dxtrade(100);

        my $app_config = BOM::Config::Runtime->instance->app_config();
        $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());
        $app_config->set({'payments.transfer_between_accounts.minimum.dxtrade' => '{"default":{"currency":"USD","amount":60}}'});

        $c->call_ok('transfer_between_accounts', $params)
            ->has_no_system_error->has_error->error_code_is('InvalidMinAmount', 'Invalid min amount hit')
            ->error_message_is('The minimum amount for transfers is 60.00 USD. Please adjust your amount.');

        $app_config->set({'payments.transfer_between_accounts.minimum.dxtrade' => '{"default":{"currency":"USD","amount":1}}'});
        $app_config->set({'payments.transfer_between_accounts.maximum.dxtrade' => '{"default":{"currency":"USD","amount":5}}'});
        $c->call_ok('transfer_between_accounts', $params)
            ->has_no_system_error->has_error->error_code_is('InvalidMaxAmount', 'Invalid max amount hit')
            ->error_message_is('The maximum amount for deposits is 5.00 USD. Please adjust your amount.');

        $app_config->set({'payments.transfer_between_accounts.maximum.dxtrade' => '{"default":{"currency":"USD","amount":110}}'});
    };

    $res = $c->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error('deposit ok')->result;

    cmp_deeply(
        $res->{accounts},
        bag({
                'account_type'     => 'binary',
                'balance'          => num($client1->account->balance),
                'currency'         => $client1->currency,
                'loginid'          => $client1->loginid,
                'account_category' => 'trading',
                'transfers'        => 'all',
                'demo_account'     => 0,
            },
            {
                'account_type'     => 'dxtrade',
                'balance'          => num(100),
                'currency'         => $dx_real->{currency},
                'loginid'          => $dx_real->{account_id},
                'market_type'      => $dx_real->{market_type},
                'transfers'        => 'all',
                'account_category' => 'trading',
                'demo_account'     => 0,
            },
        ),
        'affected accounts returned'
    );

    $params->{args}{account_from} = $dx_real->{account_id};
    $params->{args}{account_to}   = $client1->loginid;
    $params->{args}{amount}       = 100;
    $res                          = $c->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error('withdrawal ok')->result;

    cmp_deeply(
        $res->{accounts},
        bag({
                'account_type'     => 'binary',
                'balance'          => num($client1->account->balance),
                'currency'         => $client1->currency,
                'loginid'          => $client1->loginid,
                'account_category' => 'trading',
                'transfers'        => 'all',
                'demo_account'     => 0,
            },
            {
                'account_type'     => 'dxtrade',
                'balance'          => num(0),
                'currency'         => $dx_real->{currency},
                'loginid'          => $dx_real->{account_id},
                'market_type'      => $dx_real->{market_type},
                'account_category' => 'trading',
                'transfers'        => 'all',
                'demo_account'     => 0,
            },
        ),
        'affected accounts returned'
    );

    $params->{args}{account_from} = $client1->loginid;
    $params->{args}{account_to}   = $dx_real->{account_id};
    $params->{args}{amount}       = 100;
    $res = $c->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error('deposit to synthetic ok')->result;

    cmp_deeply(
        $res->{accounts},
        bag({
                'account_type'     => 'binary',
                'balance'          => num(0),
                'currency'         => $client1->currency,
                'loginid'          => $client1->loginid,
                'account_category' => 'trading',
                'transfers'        => 'all',
                'demo_account'     => 0,
            },
            {
                'account_type'     => 'dxtrade',
                'balance'          => num(100),
                'currency'         => $dx_real->{currency},
                'loginid'          => $dx_real->{account_id},
                'market_type'      => 'all',
                'account_category' => 'trading',
                'transfers'        => 'all',
                'demo_account'     => 0,
            },
        ),
        'affected accounts returned'
    );

    # Transfer from Deriv X to a crypto
    $params->{args}{account_from} = $dx_real->{account_id};
    $params->{args}{account_to}   = $client_btc->loginid;
    $params->{token}              = $token_btc;
    $params->{args}{amount}       = 100;
    $res = $c->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error('withdraw from synthetic ok')->result;

    cmp_deeply(
        $res->{accounts},
        bag({
                'account_type'     => 'binary',
                'balance'          => num(0.05, 0.01),
                'currency'         => 'BTC',
                'loginid'          => $client_btc->loginid,
                'account_category' => 'trading',
                'transfers'        => 'all',
                'demo_account'     => 0,
            },
            {
                'account_type'     => 'dxtrade',
                'balance'          => num(0),
                'currency'         => $dx_real->{currency},
                'loginid'          => $dx_real->{account_id},
                'market_type'      => 'all',
                'account_category' => 'trading',
                'transfers'        => 'all',
                'demo_account'     => 0,
            },
        ),
        'affected accounts returned'
    );
};

done_testing();
