use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Test::Deep;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Script::DevExperts;
use BOM::Platform::Token::API;
use BOM::Test::RPC::QueueClient;
use BOM::Test::Helper::Client;
use BOM::Config::Runtime;

BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(0);

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

my $client3 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
BOM::User->create(
    email    => 'transfers2@test.com',
    password => 'test'
)->add_client($client3);
$client3->account('USD');
my $token3 = BOM::Platform::Token::API->new->create_token($client3->loginid, 'test token');

my ($dx_demo, $dx_real, $dx_synthetic);

subtest 'platform deposit and withdrawal' => sub {

    my $params = {language => 'EN'};

    $c->call_ok('trading_platform_deposit',    $params)->has_no_system_error->has_error->error_code_is('InvalidToken', 'must be logged in');
    $c->call_ok('trading_platform_withdrawal', $params)->has_no_system_error->has_error->error_code_is('InvalidToken', 'must be logged in');

    $params->{token} = $token1;
    $params->{args}  = {
        platform     => 'dxtrade',
        account_type => 'demo',
        market_type  => 'financial',
        password     => 'test',
        currency     => 'USD',
    };
    $dx_demo = $c->call_ok('trading_platform_new_account', $params)->result;

    $params->{args} = {
        platform     => 'dxtrade',
        account_type => 'real',
        market_type  => 'financial',
        password     => 'test',
        currency     => 'USD',
    };
    $dx_real = $c->call_ok('trading_platform_new_account', $params)->result;

    $params->{args} = {
        platform     => 'dxtrade',
        account_type => 'real',
        market_type  => 'gaming',
        password     => 'test2',
        currency     => 'USD',
    };
    $dx_synthetic = $c->call_ok('trading_platform_new_account', $params)->result;

    $params->{args} = {
        platform     => 'dxtrade',
        from_account => $client2->loginid,
        to_account   => $dx_real->{account_id},
        amount       => 10,
    };

    $c->call_ok('trading_platform_deposit', $params)
        ->has_no_system_error->has_error->error_code_is('PlatformTransferOauthTokenRequired', 'non oauth token not allowed')
        ->error_message_is('This request must be made using a connection authorized by the Deriv account involved in the transfer.');

    $params->{args}{from_account} = $client1->loginid;
    $params->{args}{to_account}   = $dx_demo->{account_id};

    $c->call_ok('trading_platform_deposit', $params)
        ->has_no_system_error->has_error->error_code_is('PlatformTransferNoVirtual', 'Cannot deposit to demo account');

    $params->{args}{to_account} = $dx_real->{account_id};

    $c->call_ok('trading_platform_deposit', $params)->has_no_system_error->has_error->error_code_is('PlatformTransferError', 'Insufficient balance');

    BOM::Test::Helper::Client::top_up($client1, 'USD', 10);

    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(1);

    $c->call_ok('trading_platform_deposit', $params)
        ->has_no_system_error->has_error->error_code_is('DXSuspended', 'cannot deposit when dxtrade suspended');

    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(0);

    my $res = $c->call_ok('trading_platform_deposit', $params)->has_no_system_error->has_no_error->result;
    delete $res->{stash};
    cmp_deeply($res, {transaction_id => re('\d+')}, 'deposit transaction id returned');
    cmp_ok $client1->account->balance, '==', 0, 'client balance decreased';

    $params->{args} = {
        platform     => 'dxtrade',
        from_account => $dx_real->{account_id},
        to_account   => $client1->loginid,
        amount       => 10,
    };

    $res = $c->call_ok('trading_platform_withdrawal', $params)->has_no_system_error->has_no_error->result;
    delete $res->{stash};
    cmp_deeply($res, {transaction_id => re('\d+')}, 'withdrawal transaction id returned');
    cmp_ok $client1->account->balance, '==', 10, 'client balance increased';

    BOM::Test::Helper::Client::top_up($client2, 'USD', 10);
    BOM::Test::Helper::Client::top_up($client3, 'USD', 10);

    $params->{token_type} = 'oauth_token';
    $params->{args}       = {
        platform     => 'dxtrade',
        from_account => $client2->loginid,
        to_account   => $dx_real->{account_id},
        amount       => 10,
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

    my $res = $c->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error->result;
    cmp_deeply(
        $res->{accounts},
        bag({
                'account_type' => 'trading',
                'balance'      => num($client1->account->balance),
                'currency'     => $client1->currency,
                'loginid'      => $client1->loginid,
                'demo_account' => 0,
            },
            {
                'account_type' => 'trading',
                'balance'      => num($client2->account->balance),
                'currency'     => $client2->currency,
                'loginid'      => $client2->loginid,
                'demo_account' => 0,
            },
            {
                'account_type' => 'dxtrade',
                'balance'      => num(10),
                'currency'     => $dx_real->{currency},
                'loginid'      => $dx_real->{account_id},
                'market_type'  => $dx_real->{market_type},
                'demo_account' => 0,
            },
            {
                'account_type' => 'dxtrade',
                'balance'      => num(0),
                'currency'     => $dx_synthetic->{currency},
                'loginid'      => $dx_synthetic->{account_id},
                'market_type'  => 'synthetic',
                'demo_account' => 0,
            },
        ),
        'all real and demo accounts returned'
    );

    $params->{args} = {
        account_from => $client2->loginid,
        account_to   => $dx_real->{account_id},
        amount       => 10,
        currency     => 'USD',
    };

    $c->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_error->error_code_is('PlatformTransferOauthTokenRequired', 'non oauth token not allowed');

    $params->{args}{account_from} = $client1->loginid;
    $res = $c->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error('deposit ok')->result;

    cmp_deeply(
        $res->{accounts},
        bag({
                'account_type' => 'trading',
                'balance'      => num($client1->account->balance),
                'currency'     => $client1->currency,
                'loginid'      => $client1->loginid,
            },
            {
                'account_type' => 'dxtrade',
                'balance'      => num(20),
                'currency'     => $dx_real->{currency},
                'loginid'      => $dx_real->{account_id},
                'market_type'  => $dx_real->{market_type},
            },
        ),
        'affected accounts returned'
    );

    $params->{args}{account_from} = $dx_real->{account_id};
    $params->{args}{account_to}   = $client1->loginid;
    $params->{args}{amount}       = 20;
    $res                          = $c->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error('withdrawal ok')->result;

    cmp_deeply(
        $res->{accounts},
        bag({
                'account_type' => 'trading',
                'balance'      => num($client1->account->balance),
                'currency'     => $client1->currency,
                'loginid'      => $client1->loginid,
            },
            {
                'account_type' => 'dxtrade',
                'balance'      => num(0),
                'currency'     => $dx_real->{currency},
                'loginid'      => $dx_real->{account_id},
                'market_type'  => $dx_real->{market_type},
            },
        ),
        'affected accounts returned'
    );

};

done_testing();
