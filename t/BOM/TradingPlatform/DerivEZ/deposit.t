use strict;
use warnings;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use Test::More;
use Test::Fatal;
use Test::Deep;
use Test::MockModule;
use BOM::TradingPlatform;
use BOM::Test::Helper::Client;
use BOM::Config::Runtime;
use BOM::Rules::Engine;
use BOM::Config::Redis;

my $redis_ex = BOM::Config::Redis::redis_exchangerates_write;

$redis_ex->hmset(
    'exchange_rates::ETH_USD',
    offer_to_clients => 1,
    quote            => 2000,
    epoch            => time
);

$redis_ex->hmset(
    'exchange_rates::EUR_USD',
    offer_to_clients => 1,
    quote            => 1.2,
    epoch            => time
);

my $mock_fees = Test::MockModule->new('BOM::Config::CurrencyConfig');
$mock_fees->redefine(
    transfer_between_accounts_fees => {
        'ETH' => {'USD' => 5},
        'EUR' => {'USD' => 5},
    },
    get_platform_transfer_limit_by_brand => {
        'minimum' => {
            'currency' => 'USD',
            'amount'   => 0.01
        },
        'maximum' => {
            'currency' => 'USD',
            'amount'   => 100
        },
    });

subtest "deposit from CR account to DerivEZ" => sub {
    my %derivez_account = (
        real => {login => 'EZR80000000'},
    );

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    my $user   = BOM::User->create(
        email    => $client->email,
        password => 'test'
    )->add_client($client);
    $user->add_loginid($derivez_account{real}{login});
    BOM::Test::Helper::Client::top_up($client, $client->currency, 10);

    # Check for derivez TradingPlatform
    my $derivez = BOM::TradingPlatform->new(
        platform    => 'derivez',
        client      => $client,
        user        => $user,
        rule_engine => BOM::Rules::Engine->new(
            client => $client,
            user   => $user
        ),
    );
    isa_ok($derivez, 'BOM::TradingPlatform::DerivEZ');

    # Mocking BOM::MT5::User::Async to return the corrent derivez loginid
    my $mock_async_call = Test::MockModule->new('BOM::MT5::User::Async');

    # Mocking deposit to return true
    $mock_async_call->mock('deposit', sub { return Future->done({status => 1}); });

    # Preparing the response data that we get from MT5
    my $async_get_user_response = {
        'leverage'      => 1000,
        'country'       => 'Indonesia',
        'phone'         => '',
        'group'         => 'real\\p02_ts01\\all\\svg_ez_usd',
        'email'         => 'test@deriv.com',
        'address'       => '',
        'zipCode'       => undef,
        'name'          => '',
        'rights'        => 481,
        'state'         => '',
        'balance'       => '0.00',
        'phonePassword' => undef,
        'login'         => 'EZR80000000',
        'city'          => '',
        'agent'         => 0,
        'color'         => 4278190080,
        'company'       => ''
    };

    # Mocking get_user to return the user info from MT5
    $mock_async_call->mock('get_user', sub { return Future->done($async_get_user_response); });

    # Preparing the response data that we get from MT5
    my $get_group_response = {
        'currency' => 'USD',
        'group'    => 'real\\p02_ts01\\all\\svg_ez_usd',
        'leverage' => 1,
        'company'  => 'Deriv Limited'
    };

    # Mocking get_group to return group in from mt5
    $mock_async_call->mock('get_group', sub { return Future->done($get_group_response); });

    # Preparing args
    my %params = (
        to_account => 'EZR80000000',
        amount     => 5,
    );

    # Perform deposit
    cmp_deeply(exception { $derivez->deposit(%params) }, undef, 'can deposit from CR to derivez');

    # Check account balance
    is $client->account->balance, '5.00', 'deposit it correct with the amount';

    $mock_async_call->unmock_all();
};

subtest "derivez demo deposit" => sub {
    my %derivez_account = (
        demo => {login => 'EZD40100093'},
    );

    # Since we already create CR account we can reuse it
    my $client = BOM::User::Client->new({loginid => 'CR10000'});

    # Add demo derivez account
    $client->user->add_loginid($derivez_account{demo}{login});

    # Check for derivez TradingPlatform
    my $derivez = BOM::TradingPlatform->new(
        platform    => 'derivez',
        client      => $client,
        user        => $client->user,
        rule_engine => BOM::Rules::Engine->new(
            client => $client,
            user   => $client->user
        ),
    );
    isa_ok($derivez, 'BOM::TradingPlatform::DerivEZ');

    # Mocking BOM::MT5::User::Async to return the corrent derivez loginid
    my $mock_async_call = Test::MockModule->new('BOM::MT5::User::Async');

    # Mocking get_user to return the user info from MT5
    $mock_async_call->mock('deposit', sub { return Future->done({status => 1}); });

    # Preparing the response data that we get from MT5
    my $async_get_user_response = {
        'rights'        => 481,
        'balance'       => '50.00',
        'country'       => 'Indonesia',
        'state'         => '',
        'zipCode'       => undef,
        'color'         => 4278190080,
        'name'          => '',
        'phonePassword' => undef,
        'email'         => 'test@deriv.com',
        'phone'         => '+62417544552',
        'city'          => 'Cyber',
        'login'         => 'EZD40100093',
        'group'         => 'demo\\p01_ts04\\all\\svg_ez_usd',
        'leverage'      => 1000,
        'address'       => 'ADDR 1',
        'agent'         => 0,
        'company'       => ''
    };

    # Mocking get_user to return the user info from MT5
    $mock_async_call->mock('get_user', sub { return Future->done($async_get_user_response); });

    # Preparing the response data that we get from MT5
    my $get_group_response = {
        'currency' => 'USD',
        'group'    => 'demo\\p01_ts04\\all\\svg_ez_usd',
        'leverage' => 1,
        'company'  => 'Deriv Limited'
    };

    # Mocking get_group to return group in from mt5
    $mock_async_call->mock('get_group', sub { return Future->done($get_group_response); });

    # Preparing args
    my %params = (
        to_account => 'EZD40100093',
        amount     => 1000,
    );

    # Perform test
    cmp_deeply(
        $derivez->deposit(%params),
        {
            status => 1,
        },
        'can do derivez demo deposit'
    );

    $mock_async_call->unmock_all();
};

subtest "cannot deposit if payment is suspended" => sub {
    # Since we already create CR account we can reuse it
    my $client = BOM::User::Client->new({loginid => 'CR10000'});

    # Check for derivez TradingPlatform
    my $derivez = BOM::TradingPlatform->new(
        platform    => 'derivez',
        client      => $client,
        user        => $client->user,
        rule_engine => BOM::Rules::Engine->new(
            client => $client,
            user   => $client->user
        ),
    );
    isa_ok($derivez, 'BOM::TradingPlatform::DerivEZ');

    # Preparing args
    my %params = (
        to_account => 'EZR80000000',
        amount     => 5,
    );

    # Suspending payment
    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->system->suspend->payments(1);

    # Perform test
    cmp_deeply(exception { $derivez->deposit(%params) }, {code => 'PaymentsSuspended'}, 'cannot deposit if payment is suspended');

    $app_config->system->suspend->payments(0);
};

subtest "cannot deposit if derivez login is not provided" => sub {
    # Since we already create CR account we can reuse it
    my $client = BOM::User::Client->new({loginid => 'CR10000'});

    # Check for derivez TradingPlatform
    my $derivez = BOM::TradingPlatform->new(
        platform    => 'derivez',
        client      => $client,
        user        => $client->user,
        rule_engine => BOM::Rules::Engine->new(
            client => $client,
            user   => $client->user
        ),
    );
    isa_ok($derivez, 'BOM::TradingPlatform::DerivEZ');

    # Preparing args
    my %params = (
        amount => 5,
    );

    # Perform test
    cmp_deeply(exception { $derivez->deposit(%params) }, {code => 'DerivEZMissingID'}, 'cannot deposit if derivez login is missing');
    cmp_deeply(exception { $derivez->deposit(%params, to_account => '') }, {code => 'DerivEZMissingID'}, 'cannot deposit if derivez login is empty');
};

subtest "cannot deposit if derivez account does not belong to client" => sub {
    # Since we already create CR account we can reuse it
    my $client = BOM::User::Client->new({loginid => 'CR10000'});

    # Check for derivez TradingPlatform
    my $derivez = BOM::TradingPlatform->new(
        platform    => 'derivez',
        client      => $client,
        user        => $client->user,
        rule_engine => BOM::Rules::Engine->new(
            client => $client,
            user   => $client->user
        ),
    );
    isa_ok($derivez, 'BOM::TradingPlatform::DerivEZ');

    # Preparing args
    my %params = (
        to_account => 'EZR80000001',
        amount     => 5,
    );

    # Perform test
    cmp_deeply(exception { $derivez->deposit(%params) }, {code => 'PermissionDenied'}, 'cannot deposit if derivez account does not belong to client');
};

subtest "can deposit with exchange rate applied from eth to usd" => sub {
    # Since we already create CR account we can reuse it
    my $client = BOM::User::Client->new({loginid => 'CR10000'});

    # Create an account with ETH currency
    my $client_eth = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    $client_eth->account('ETH');

    # Add the new ETH client to user
    $client->user->add_client($client_eth);

    # Add MT5 account
    BOM::Test::Helper::Client::top_up($client_eth, 'ETH', 0.1);

    # Check for derivez TradingPlatform
    my $derivez = BOM::TradingPlatform->new(
        platform    => 'derivez',
        client      => $client_eth,
        user        => $client_eth->user,
        rule_engine => BOM::Rules::Engine->new(
            client => $client_eth,
            user   => $client_eth->user
        ),
    );
    isa_ok($derivez, 'BOM::TradingPlatform::DerivEZ');

    # Mocking BOM::MT5::User::Async to return the corrent derivez loginid
    my $mock_async_call = Test::MockModule->new('BOM::MT5::User::Async');

    # Preparing the response data that we get from MT5
    my $async_get_user_response = {
        'leverage'      => 1000,
        'country'       => 'Indonesia',
        'phone'         => '',
        'group'         => 'real\\p02_ts01\\all\\svg_ez_usd',
        'email'         => 'test@deriv.com',
        'address'       => '',
        'zipCode'       => undef,
        'name'          => '',
        'rights'        => 481,
        'state'         => '',
        'balance'       => '0.00',
        'phonePassword' => undef,
        'login'         => 'EZR80000000',
        'city'          => '',
        'agent'         => 0,
        'color'         => 4278190080,
        'company'       => ''
    };

    # Mocking get_user to return the user info from MT5
    $mock_async_call->mock('get_user', sub { return Future->done($async_get_user_response); });

    # Preparing the response data that we get from MT5
    my $get_group_response = {
        'currency' => 'USD',
        'group'    => 'real\\p02_ts01\\all\\svg_ez_usd',
        'leverage' => 1,
        'company'  => 'Deriv Limited'
    };

    # Mocking get_group to return group in from mt5
    $mock_async_call->mock('get_group', sub { return Future->done($get_group_response); });

    my $received_amount;
    my $count;
    # Mocking deposit to return true
    $mock_async_call->mock(
        'deposit',
        sub {
            my ($variable) = @_;

            $received_amount = $variable->{amount};
            $count++;

            return Future->done({status => 1});
        });

    # Preparing args
    my %params = (
        to_account => 'EZR80000000',
        amount     => 0.05,
    );

    # # Perform test
    cmp_deeply(exception { $derivez->deposit(%params) }, undef, 'can deposit from derivez to CR with ETH currency');

    # # Check account balance
    is $client_eth->account->balance, '0.05000000', 'balance is correct';
    my $expected_amount = sprintf('%.2f', (0.05 * 0.95) * 2000);
    cmp_ok $received_amount, '==', $expected_amount, 'deposit to derivez is correct after applying exchange rate & fee';

    # Check if deposit run only once
    is $count, 1, 'deposit run only once';

    $mock_async_call->unmock_all();
};

subtest "amount does not meet the min requirements" => sub {
    # Since we already create CR account we can reuse it
    my $client     = BOM::User::Client->new({loginid => 'CR10000'});
    my $client_eth = BOM::User::Client->new({loginid => 'CR10001'});

    # Check for derivez TradingPlatform
    my $derivez = BOM::TradingPlatform->new(
        platform    => 'derivez',
        client      => $client,
        user        => $client->user,
        rule_engine => BOM::Rules::Engine->new(
            client => $client,
            user   => $client->user
        ),
    );
    isa_ok($derivez, 'BOM::TradingPlatform::DerivEZ');

    # Check for derivez eth account TradingPlatform
    my $derivez_eth = BOM::TradingPlatform->new(
        platform    => 'derivez',
        client      => $client_eth,
        user        => $client_eth->user,
        rule_engine => BOM::Rules::Engine->new(
            client => $client_eth,
            user   => $client_eth->user
        ),
    );
    isa_ok($derivez_eth, 'BOM::TradingPlatform::DerivEZ');

    # Mocking BOM::MT5::User::Async to return the corrent derivez loginid
    my $mock_async_call = Test::MockModule->new('BOM::MT5::User::Async');

    # Preparing and mock get_user response data that we get from MT5
    my $async_get_user_response = {
        'leverage'      => 1000,
        'country'       => 'Indonesia',
        'phone'         => '',
        'group'         => 'real\\p02_ts01\\all\\svg_ez_usd',
        'email'         => 'test@deriv.com',
        'address'       => '',
        'zipCode'       => undef,
        'name'          => '',
        'rights'        => 481,
        'state'         => '',
        'balance'       => '0.00',
        'phonePassword' => undef,
        'login'         => 'EZR80000000',
        'city'          => '',
        'agent'         => 0,
        'color'         => 4278190080,
        'company'       => ''
    };
    $mock_async_call->mock('get_user', sub { return Future->done($async_get_user_response); });

    # Preparing and mock get_group response data that we get from MT5
    my $get_group_response = {
        'currency' => 'USD',
        'group'    => 'real\\p02_ts01\\all\\svg_ez_usd',
        'leverage' => 1,
        'company'  => 'Deriv Limited'
    };
    $mock_async_call->mock('get_group', sub { return Future->done($get_group_response); });

    # Preparing args for testing
    my %params = (
        to_account => 'EZR80000000',
        amount     => 0.001,
    );

    # Perform test
    cmp_deeply(
        exception { $derivez->deposit(%params) },
        {
            code   => 'InvalidMinAmount',
            params => ['0.01', 'USD']
        },
        'amount does not meet the min requirements'
    );

    # Setting params to eth user
    $params{amount} = 0.00000001;

    # Perform test
    cmp_deeply(
        exception { $derivez_eth->deposit(%params) },
        {
            code   => 'InvalidMinAmount',
            params => ['0.00000500', 'ETH']
        },
        'amount does not meet the min requirements (ETH)'
    );

    $mock_async_call->unmock_all();
};

subtest "amount exceed the max_transfer_limit requirements" => sub {
    # Since we already create CR account we can reuse it
    my $client     = BOM::User::Client->new({loginid => 'CR10000'});
    my $client_eth = BOM::User::Client->new({loginid => 'CR10001'});

    BOM::Test::Helper::Client::top_up($client,     'USD', 200);
    BOM::Test::Helper::Client::top_up($client_eth, 'ETH', 0.1);

    # Check for derivez TradingPlatform
    my $derivez = BOM::TradingPlatform->new(
        platform    => 'derivez',
        client      => $client,
        user        => $client->user,
        rule_engine => BOM::Rules::Engine->new(
            client => $client,
            user   => $client->user
        ),
    );
    isa_ok($derivez, 'BOM::TradingPlatform::DerivEZ');

    # Check for derivez ETH TradingPlatform
    my $derivez_eth = BOM::TradingPlatform->new(
        platform    => 'derivez',
        client      => $client_eth,
        user        => $client_eth->user,
        rule_engine => BOM::Rules::Engine->new(
            client => $client_eth,
            user   => $client_eth->user
        ),
    );
    isa_ok($derivez, 'BOM::TradingPlatform::DerivEZ');

    # Mocking BOM::MT5::User::Async to return the corrent derivez loginid
    my $mock_async_call = Test::MockModule->new('BOM::MT5::User::Async');

    # Preparing and mock get_user response data that we get from MT5
    my $async_get_user_response = {
        'leverage'      => 1000,
        'country'       => 'Indonesia',
        'phone'         => '',
        'group'         => 'real\\p02_ts01\\all\\svg_ez_usd',
        'email'         => 'test@deriv.com',
        'address'       => '',
        'zipCode'       => undef,
        'name'          => '',
        'rights'        => 481,
        'state'         => '',
        'balance'       => '0.00',
        'phonePassword' => undef,
        'login'         => 'EZR80000000',
        'city'          => '',
        'agent'         => 0,
        'color'         => 4278190080,
        'company'       => ''
    };
    $mock_async_call->mock('get_user', sub { return Future->done($async_get_user_response); });

    # Preparing and mock get_group response data that we get from MT5
    my $get_group_response = {
        'currency' => 'USD',
        'group'    => 'real\\p02_ts01\\all\\svg_ez_usd',
        'leverage' => 1,
        'company'  => 'Deriv Limited'
    };
    $mock_async_call->mock('get_group', sub { return Future->done($get_group_response); });

    # Preparing args for testing
    my %params = (
        to_account => 'EZR80000000',
        amount     => 101,
    );

    #Perform test
    cmp_deeply(
        exception { $derivez->deposit(%params) },
        {
            code   => 'InvalidMaxAmount',
            params => ['100.00', 'USD']
        },
        'amount exceeds the max_transfer_limit requirements'
    );

    # Setting params to eth user
    $params{amount} = 0.051;

    # Perform test
    cmp_deeply(
        exception { $derivez_eth->deposit(%params) },
        {
            code   => 'InvalidMaxAmount',
            params => ['0.05000000', 'ETH']
        },
        'amount exceeds the max_transfer_limit requirements (ETH)'
    );

    $mock_async_call->unmock_all();
};

subtest "amount is valid" => sub {
    # Since we already create CR account we can reuse it
    my $client = BOM::User::Client->new({loginid => 'CR10000'});

    # Check for derivez TradingPlatform
    my $derivez = BOM::TradingPlatform->new(
        platform    => 'derivez',
        client      => $client,
        user        => $client->user,
        rule_engine => BOM::Rules::Engine->new(
            client => $client,
            user   => $client->user
        ),
    );
    isa_ok($derivez, 'BOM::TradingPlatform::DerivEZ');

    # Mocking BOM::MT5::User::Async to return the corrent derivez loginid
    my $mock_async_call = Test::MockModule->new('BOM::MT5::User::Async');

    # Preparing and mock get_user response data that we get from MT5
    my $async_get_user_response = {
        'leverage'      => 1000,
        'country'       => 'Indonesia',
        'phone'         => '',
        'group'         => 'real\\p02_ts01\\all\\svg_ez_usd',
        'email'         => 'test@deriv.com',
        'address'       => '',
        'zipCode'       => undef,
        'name'          => '',
        'rights'        => 481,
        'state'         => '',
        'balance'       => '0.00',
        'phonePassword' => undef,
        'login'         => 'EZR80000000',
        'city'          => '',
        'agent'         => 0,
        'color'         => 4278190080,
        'company'       => ''
    };
    $mock_async_call->mock('get_user', sub { return Future->done($async_get_user_response); });

    # Preparing and mock get_group response data that we get from MT5
    my $get_group_response = {
        'currency' => 'USD',
        'group'    => 'real\\p02_ts01\\all\\svg_ez_usd',
        'leverage' => 1,
        'company'  => 'Deriv Limited'
    };
    $mock_async_call->mock('get_group', sub { return Future->done($get_group_response); });

    # Preparing args for testing
    my %params = (
        to_account => 'EZR80000000',
        amount     => 10.888,
    );

    # Perform test
    cmp_deeply(
        exception { $derivez->deposit(%params) },
        {
            code    => 'DerivEZDepositError',
            message => 'Invalid amount. Amount provided can not have more than 2 decimal places.'
        },
        'amount is valid'
    );

    $mock_async_call->unmock_all();
};

subtest "can deposit with exchange rate applied from eur to usd" => sub {
    # Since we already create CR account we can reuse it
    my $client = BOM::User::Client->new({loginid => 'CR10000'});

    # Create an account with EUR currency
    my $client_eur = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    $client_eur->account('EUR');

    # Add the new EUR client to user
    $client->user->add_client($client_eur);

    # Add MT5 account
    BOM::Test::Helper::Client::top_up($client_eur, 'EUR', 10);

    # Check for derivez TradingPlatform
    my $derivez = BOM::TradingPlatform->new(
        platform    => 'derivez',
        client      => $client_eur,
        user        => $client_eur->user,
        rule_engine => BOM::Rules::Engine->new(
            client => $client_eur,
            user   => $client_eur->user
        ),
    );
    isa_ok($derivez, 'BOM::TradingPlatform::DerivEZ');

    # Mocking BOM::MT5::User::Async to return the corrent derivez loginid
    my $mock_async_call = Test::MockModule->new('BOM::MT5::User::Async');

    # Preparing and mock get_user response data that we get from MT5
    my $async_get_user_response = {
        'leverage'      => 1000,
        'country'       => 'Indonesia',
        'phone'         => '',
        'group'         => 'real\\p02_ts01\\all\\svg_ez_usd',
        'email'         => 'test@deriv.com',
        'address'       => '',
        'zipCode'       => undef,
        'name'          => '',
        'rights'        => 481,
        'state'         => '',
        'balance'       => '0.00',
        'phonePassword' => undef,
        'login'         => 'EZR80000000',
        'city'          => '',
        'agent'         => 0,
        'color'         => 4278190080,
        'company'       => ''
    };
    $mock_async_call->mock('get_user', sub { return Future->done($async_get_user_response); });

    # Preparing and mock get_group response data that we get from MT5
    my $get_group_response = {
        'currency' => 'USD',
        'group'    => 'real\\p02_ts01\\all\\svg_ez_usd',
        'leverage' => 1,
        'company'  => 'Deriv Limited'
    };
    $mock_async_call->mock('get_group', sub { return Future->done($get_group_response); });

    my $received_amount;
    my $count;
    # Mocking deposit to return true
    $mock_async_call->mock(
        'deposit',
        sub {
            my ($variable) = @_;

            $received_amount = $variable->{amount};
            $count++;

            return Future->done({status => 1});
        });

    # Preparing args
    my %params = (
        to_account => 'EZR80000000',
        amount     => 5,
    );

    # Perform test
    cmp_deeply(exception { $derivez->deposit(%params) }, undef, 'can deposit from derivez to CR with EUR currency');

    # Check account balance
    is $client_eur->account->balance, '5.00', 'deposit is correct';
    my $expected_amount = sprintf('%.2f', (5 * 0.95) * 1.2);
    cmp_ok $received_amount, '==', $expected_amount, 'deposit to derivez is correct after applying exchange rate & fee';

    # Check if deposit run only once
    is $count, 1, 'deposit run only once';

    $mock_async_call->unmock_all();
};

done_testing();
