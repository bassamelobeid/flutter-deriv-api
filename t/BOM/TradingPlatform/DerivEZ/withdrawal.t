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

subtest "withdrawal from DerivEZ to CR account" => sub {
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
        platform => 'derivez',
        client   => $client
    );
    isa_ok($derivez, 'BOM::TradingPlatform::DerivEZ');

    # Mocking BOM::MT5::User::Async to return the corrent derivez loginid
    my $mock_async_call = Test::MockModule->new('BOM::MT5::User::Async');

    # Mocking withdrawal to return true
    $mock_async_call->mock('withdrawal', sub { return Future->done({status => 1}); });

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
        from_account => 'EZR80000000',
        to_account   => 'CR10000',
        amount       => 5,
        currency     => 'USD',
    );

    # Perform wihtdrawal
    cmp_deeply(exception { $derivez->withdraw(%params) }, undef, 'can withdraw from derivez to CR');

    # Check account balance
    is $client->account->balance, '15.00', 'withdrawal is correct and applying exchange rate';

    $mock_async_call->unmock_all();
};

subtest "cannot withdraw if payment is suspended" => sub {
    # Since we already create CR account we can reuse it
    my $client = BOM::User::Client->new({loginid => 'CR10000'});

    # Check for derivez TradingPlatform
    my $derivez = BOM::TradingPlatform->new(
        platform    => 'derivez',
        client      => $client,
        rule_engine => BOM::Rules::Engine->new(client => $client),
    );
    isa_ok($derivez, 'BOM::TradingPlatform::DerivEZ');

    # Preparing args
    my %params = (
        from_account => 'EZR80000000',
        to_account   => 'CR10000',
        amount       => 5,
        currency     => 'USD',
    );

    # Suspending payment
    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->system->suspend->payments(1);

    # Perform test
    cmp_deeply(exception { $derivez->withdraw(%params) }, {code => 'PaymentsSuspended'}, 'cannot withdraw if payment is suspended');

    $app_config->system->suspend->payments(0);
};

subtest "cannot withdraw if derivez login is not provided" => sub {
    # Since we already create CR account we can reuse it
    my $client = BOM::User::Client->new({loginid => 'CR10000'});

    # Check for derivez TradingPlatform
    my $derivez = BOM::TradingPlatform->new(
        platform    => 'derivez',
        client      => $client,
        rule_engine => BOM::Rules::Engine->new(client => $client),
    );
    isa_ok($derivez, 'BOM::TradingPlatform::DerivEZ');

    # Preparing args
    my %params = (
        from_account => '',
        to_account   => 'CR10000',
        amount       => 5,
        currency     => 'USD',
    );

    # Perform test
    cmp_deeply(exception { $derivez->withdraw(%params) }, {code => 'DerivEZMissingID'}, 'cannot withdraw if derivez login is not provided');
};

subtest "cannot withdraw if derivez account does not belong to client" => sub {
    # Since we already create CR account we can reuse it
    my $client = BOM::User::Client->new({loginid => 'CR10000'});

    # Check for derivez TradingPlatform
    my $derivez = BOM::TradingPlatform->new(
        platform    => 'derivez',
        client      => $client,
        rule_engine => BOM::Rules::Engine->new(client => $client),
    );
    isa_ok($derivez, 'BOM::TradingPlatform::DerivEZ');

    # Preparing args
    my %params = (
        from_account => 'EZR80000001',
        to_account   => 'CR10000',
        amount       => 5,
        currency     => 'USD',
    );

    # Perform test
    cmp_deeply(
        exception { $derivez->withdraw(%params) },
        {
            code    => 'PermissionDenied',
            message => 'Both accounts should belong to the authorized client.'
        },
        'cannot withdraw if derivez account does not belong to client'
    );
};

subtest "cannot withdraw between cfd account" => sub {
    # Since we already create CR account we can reuse it
    my $client = BOM::User::Client->new({loginid => 'CR10000'});

    # Add MT5 account
    $client->user->add_loginid('MTR5123');

    # Check for derivez TradingPlatform
    my $derivez = BOM::TradingPlatform->new(
        platform    => 'derivez',
        client      => $client,
        rule_engine => BOM::Rules::Engine->new(client => $client),
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

    # Preparing args
    my %params = (
        from_account => 'EZR80000000',
        to_account   => 'MTR5123',
        amount       => 5,
        currency     => 'USD',
    );

    # Perform test
    cmp_deeply(
        exception { $derivez->withdraw(%params) },
        {
            code    => 'PermissionDenied',
            message => 'Transfer between cfd account is not permitted.'
        },
        'cannot withdraw between cfd account'
    );

    $mock_async_call->unmock_all();
};

subtest "can withdraw with exchange rate applied from usd to eth" => sub {
    # Since we already create CR account we can reuse it
    my $client = BOM::User::Client->new({loginid => 'CR10000'});

    # Create an account with ETH currency
    my $client_eth = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    $client_eth->account('ETH');

    # Add the new ETH client to user
    $client->user->add_client($client_eth);

    # Top up ETH account
    BOM::Test::Helper::Client::top_up($client_eth, 'ETH', 10);

    # Check for derivez TradingPlatform
    my $derivez = BOM::TradingPlatform->new(
        platform    => 'derivez',
        client      => $client_eth,
        rule_engine => BOM::Rules::Engine->new(client => $client_eth),
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

    # Mocking withdrawal to return true
    $mock_async_call->mock('withdrawal', sub { return Future->done({status => 1}); });

    # Setting redis exchange rate since this is test env
    my $redis = BOM::Config::Redis::redis_exchangerates_write();
    $redis->hmset(
        'exchange_rates::ETH_USD',
        offer_to_clients => 1,
        quote            => '1919.99500',
        epoch            => time
    );

    # Preparing args
    my %params = (
        from_account => 'EZR80000000',
        to_account   => 'CR10001',
        amount       => 5,
        currency     => 'USD',
    );

    # Perform test
    cmp_deeply(exception { $derivez->withdraw(%params) }, undef, 'can withdraw from derivez to CR with ETH currency');

    # Check account balance
    is $client_eth->account->balance, '10.00257813', 'withdrawal is correct and applying exchange rate';

    $mock_async_call->unmock_all();
};

subtest "amount does not meet the min requirements" => sub {
    # Since we already create CR account we can reuse it
    my $client = BOM::User::Client->new({loginid => 'CR10000'});

    # Check for derivez TradingPlatform
    my $derivez = BOM::TradingPlatform->new(
        platform    => 'derivez',
        client      => $client,
        rule_engine => BOM::Rules::Engine->new(client => $client),
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
        from_account => 'EZR80000000',
        to_account   => 'CR10000',
        amount       => 0.001,
        currency     => 'USD',
    );

    # Perform test
    cmp_deeply(
        exception { $derivez->withdraw(%params) },
        {
            code    => 'InvalidMinAmount',
            message => undef
        },
        'amount does not meet the min requirements'
    );

    $mock_async_call->unmock_all();
};

subtest "amount exceed the max_transfer_limit requirements" => sub {
    # Since we already create CR account we can reuse it
    my $client = BOM::User::Client->new({loginid => 'CR10000'});

    # Check for derivez TradingPlatform
    my $derivez = BOM::TradingPlatform->new(
        platform    => 'derivez',
        client      => $client,
        rule_engine => BOM::Rules::Engine->new(client => $client),
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
        from_account => 'EZR80000000',
        to_account   => 'CR10000',
        amount       => 15001,
        currency     => 'USD',
    );

    # Perform test
    cmp_deeply(
        exception { $derivez->withdraw(%params) },
        {
            code    => 'InvalidMaxAmount',
            message => undef
        },
        'amount exceed the max_transfer_limit requirements'
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
        rule_engine => BOM::Rules::Engine->new(client => $client),
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
        from_account => 'EZR80000000',
        to_account   => 'CR10000',
        amount       => 10.888,
        currency     => 'USD',
    );

    # Perform test
    cmp_deeply(
        exception { $derivez->withdraw(%params) },
        {
            code    => 'DerivEZWithdrawalError',
            message => 'Invalid amount. Amount provided can not have more than 2 decimal places.'
        },
        'amount is valid'
    );

    $mock_async_call->unmock_all();
};

subtest "can withdraw with exchange rate applied from usd to eur" => sub {
    # Since we already create CR account we can reuse it
    my $client = BOM::User::Client->new({loginid => 'CR10000'});

    # Create an account with EUR currency
    my $client_eur = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    $client_eur->account('EUR');

    # Add the new EUR client to user
    $client->user->add_client($client_eur);

    # Check for derivez TradingPlatform
    my $derivez = BOM::TradingPlatform->new(
        platform    => 'derivez',
        client      => $client_eur,
        rule_engine => BOM::Rules::Engine->new(client => $client_eur),
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

    # Mocking withdrawal to return true
    $mock_async_call->mock('withdrawal', sub { return Future->done({status => 1}); });

    # Setting redis exchange rate since this is test env
    my $redis = BOM::Config::Redis::redis_exchangerates_write();
    $redis->hmset(
        'exchange_rates::EUR_USD',
        offer_to_clients => 1,
        quote            => '1.09113',
        epoch            => time
    );

    # Preparing args
    my %params = (
        from_account => 'EZR80000000',
        to_account   => 'CR10002',
        amount       => 8,
        currency     => 'USD',
    );

    # Perform test
    cmp_deeply(exception { $derivez->withdraw(%params) }, undef, 'can withdraw from derivez to CR with EUR currency');

    # Check account balance
    is $client_eur->account->balance, '7.26', 'withdrawal is correct and applying exchange rate';

    $mock_async_call->unmock_all();
};

done_testing();
