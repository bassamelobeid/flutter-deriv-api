use strict;
use warnings;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use Test::More;
use Test::Deep;
use Test::Fatal;
use Test::MockModule;
use BOM::TradingPlatform;
use BOM::Config::Runtime;
use BOM::Rules::Engine;

# Setting up app config for demo and real server
my $app_config = BOM::Config::Runtime->instance->app_config;
$app_config->system->mt5->http_proxy->demo->p01_ts04(1);
$app_config->system->mt5->http_proxy->real->p02_ts01(1);

subtest "able to create new derivez account using svg landing company (demo)" => sub {
    # Create new deriv CR account
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    my $user   = BOM::User->create(
        email    => $client->email,
        password => 'test'
    )->add_client($client);

    # Set default account currency
    $client->set_default_account('USD');

    # Preparing the parameters for new derivez account creation
    my %params = (
        account_type => 'demo',
        market_type  => 'all',
        platform     => 'derivez',
        currency     => 'USD',
        company      => 'svg'
    );

    # Check for derivez TradingPlatform
    my $derivez = BOM::TradingPlatform->new(
        platform    => 'derivez',
        client      => $client,
        rule_engine => BOM::Rules::Engine->new(client => $client),
    );
    isa_ok($derivez, 'BOM::TradingPlatform::DerivEZ');

    # Mocking BOM::MT5::User::Async for testing purposes
    my $mock_mt5 = Test::MockModule->new('BOM::MT5::User::Async');

    # Mocking get_user to return undef to make sure user dont have any derivez account yet
    $mock_mt5->mock('get_user', sub { return 'undef'; });

    # Mocking create_user to create a new derivez user
    $mock_mt5->mock('create_user', sub { return Future->done({login => "EZD40100000"}); });

    # Mocking deposit to deposit demo account
    $mock_mt5->mock('deposit', sub { return Future->done({status => 1}); });

    # Preparing the response data that we get from MT5
    my $get_group_response = {
        'currency' => 'USD',
        'group'    => 'demo\\p01_ts04\\all\\svg_ez_usd',
        'leverage' => 1,
        'company'  => 'Deriv Limited'
    };

    # Mocking get_group to return group in from mt5
    $mock_mt5->mock('get_group', sub { return Future->done($get_group_response); });

    # Preparing the correct response from account creation
    my $response = {
        'landing_company_short' => 'svg',
        'balance'               => 10000,
        'market_type'           => 'all',
        'display_balance'       => '10000.00',
        'currency'              => 'USD',
        'login'                 => 'EZD40100000',
        'account_type'          => 'demo',
        'platform'              => 'derivez',
        'agent'                 => undef
    };

    # Derivez new account creation test
    cmp_deeply($derivez->new_account(%params), $response, 'can create new derivez accounts (demo)');

    $mock_mt5->unmock_all();
};

subtest "able to create new derivez account using svg landing company (real)" => sub {
    # Since we already create CR account we can reuse it
    my $client = BOM::User::Client->new({loginid => 'CR10000'});

    # Preparing the parameters for new derivez account creation
    my %params = (
        account_type => 'real',
        market_type  => 'all',
        platform     => 'derivez',
        currency     => 'USD',
        company      => 'svg'
    );

    # Check for derivez TradingPlatform
    my $derivez = BOM::TradingPlatform->new(
        platform    => 'derivez',
        client      => $client,
        rule_engine => BOM::Rules::Engine->new(client => $client),
    );
    isa_ok($derivez, 'BOM::TradingPlatform::DerivEZ');

    # Mocking BOM::MT5::User::Async for testing purposes
    my $mock_mt5 = Test::MockModule->new('BOM::MT5::User::Async');

    # Mocking get_user to return undef to make sure user dont have any derivez account yet
    $mock_mt5->mock('get_user', sub { return 'undef'; });

    # Mocking create_user to create a new derivez user
    $mock_mt5->mock('create_user', sub { return Future->done({login => "EZR80000000"}); });

    # Mocking deposit to deposit demo account
    $mock_mt5->mock('deposit', sub { return Future->done({status => 1}); });

    # Preparing the response data that we get from MT5
    my $get_group_response = {
        'currency' => 'USD',
        'group'    => 'real\\p02_ts01\\all\\svg_ez_usd',
        'leverage' => 1,
        'company'  => 'Deriv Limited'
    };

    # Mocking get_group to return group in from mt5
    $mock_mt5->mock('get_group', sub { return Future->done($get_group_response); });

    # Preparing the correct response from account creation
    my $response = {
        'landing_company_short' => 'svg',
        'balance'               => 0,
        'market_type'           => 'all',
        'display_balance'       => '0.00',
        'currency'              => 'USD',
        'login'                 => 'EZR80000000',
        'account_type'          => 'real',
        'platform'              => 'derivez',
        'agent'                 => undef
    };

    # Derivez new account creation test
    cmp_deeply($derivez->new_account(%params), $response, 'can create new derivez accounts (real)');

    $mock_mt5->unmock_all();
};

subtest "able to show derivez account using get_accounts (demo)" => sub {
    # Since we already create CR account we can reuse it
    my $client = BOM::User::Client->new({loginid => 'CR10000'});

    # Preparing the parameters for derivez get account
    my %params = (
        platform => 'derivez',
        type     => 'demo'
    );

    # Check for derivez TradingPlatform
    my $derivez = BOM::TradingPlatform->new(
        platform    => 'derivez',
        client      => $client,
        rule_engine => BOM::Rules::Engine->new(client => $client),
    );
    isa_ok($derivez, 'BOM::TradingPlatform::DerivEZ');

    # Mocking BOM::MT5::User::Async to return the corrent derivez loginid
    my $mock_mt5 = Test::MockModule->new('BOM::MT5::User::Async');

    # Preparing the response data that we get from MT5
    my $async_get_user_response = {
        'rights'        => 481,
        'balance'       => '10000.00',
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
    $mock_mt5->mock('get_user', sub { return Future->done($async_get_user_response); });

    # Preparing the response data that we get from MT5
    my $get_group_response = {
        'currency' => 'USD',
        'group'    => 'demo\\p01_ts04\\all\\svg_ez_usd',
        'leverage' => 1,
        'company'  => 'Deriv Limited'
    };

    # Mocking get_group to return group in from mt5
    $mock_mt5->mock('get_group', sub { return Future->done($get_group_response); });

    # Preparing the correct response for derivez get_accounts
    my $response = [{
            'currency'              => 'USD',
            'leverage'              => 1000,
            'email'                 => 'test@deriv.com',
            'login'                 => 'EZD40100093',
            'landing_company_short' => 'svg',
            'server_info'           => {
                'environment' => 'Deriv-Demo',
                'geolocation' => {
                    'location' => 'Frankfurt',
                    'sequence' => 1,
                    'group'    => 'derivez',
                    'region'   => 'Europe'
                },
                'id' => 'p01_ts04'
            },
            'balance'         => '10000.00',
            'country'         => 'id',
            'market_type'     => 'all',
            'account_type'    => 'demo',
            'name'            => '',
            'server'          => 'p01_ts04',
            'group'           => 'demo\\p01_ts04\\all\\svg_ez_usd',
            'display_balance' => '10000.00'
        }];

    # Derivez get_accounts test
    cmp_deeply($derivez->get_accounts(%params), $response, 'can get derivez accounts (demo)');

    subtest "should show error if demo_01_ts04 is suspended" => sub {
        # Suspending the demo_p01_ts04 server
        $app_config->system->mt5->suspend->demo->p01_ts04->all(1);

        # Preparing the expected error response
        my $error_response = [{
                'details' => {
                    'account_type' => 'demo',
                    'login'        => 'EZD40100000',
                    'server'       => 'p01_ts04',
                    'server_info'  => {
                        'environment' => 'Deriv-Demo',
                        'geolocation' => {
                            'location' => 'Frankfurt',
                            'sequence' => 1,
                            'group'    => 'derivez',
                            'region'   => 'Europe'
                        },
                        'id' => 'p01_ts04'
                    },
                },
                'code'    => 'DerivEZAccountInaccessible',
                'message' => 'Deriv EZ is currently unavailable. Please try again later.',
            }];

        # Perform test
        cmp_deeply(exception { $derivez->get_accounts(%params) }, $error_response, 'receive error when get derivez accounts (demo)');

        # Finish test and unsuspeding the server
        $app_config->system->mt5->suspend->demo->p01_ts04->all(0);
    };

    $mock_mt5->unmock_all();
};

subtest "able to show derivez account using get_accounts (real)" => sub {
    # Since we already create CR account we can reuse it
    my $client = BOM::User::Client->new({loginid => 'CR10000'});

    # Preparing the parameters for derivez get account
    my %params = (
        platform => 'derivez',
        type     => 'real'
    );

    # Check for derivez TradingPlatform
    my $derivez = BOM::TradingPlatform->new(
        platform    => 'derivez',
        client      => $client,
        rule_engine => BOM::Rules::Engine->new(client => $client),
    );
    isa_ok($derivez, 'BOM::TradingPlatform::DerivEZ');

    # Mocking BOM::MT5::User::Async to return the corrent derivez loginid
    my $mock_mt5 = Test::MockModule->new('BOM::MT5::User::Async');

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
    $mock_mt5->mock('get_user', sub { return Future->done($async_get_user_response); });

    # Preparing the response data that we get from MT5
    my $get_group_response = {
        'currency' => 'USD',
        'group'    => 'real\\p02_ts01\\all\\svg_ez_usd',
        'leverage' => 1,
        'company'  => 'Deriv Limited'
    };

    # Mocking get_group to return group in from mt5
    $mock_mt5->mock('get_group', sub { return Future->done($get_group_response); });

    # Preparing the correct response for derivez get_accounts
    my $response = [{
            'server'                => 'p02_ts01',
            'display_balance'       => '0.00',
            'account_type'          => 'real',
            'landing_company_short' => 'svg',
            'login'                 => 'EZR80000000',
            'group'                 => 'real\\p02_ts01\\all\\svg_ez_usd',
            'balance'               => '0.00',
            'server_info'           => {
                'geolocation' => {
                    'region'   => 'Africa',
                    'location' => 'South Africa',
                    'sequence' => 2,
                    'group'    => 'africa_derivez'
                },
                'id'          => 'p02_ts01',
                'environment' => 'Deriv-Server-02'
            },
            'country'     => 'id',
            'currency'    => 'USD',
            'name'        => '',
            'email'       => 'test@deriv.com',
            'market_type' => 'all',
            'leverage'    => 1000
        }];

    # Derivez get_accounts test
    cmp_deeply($derivez->get_accounts(%params), $response, 'can get derivez accounts (real)');

    subtest "should show error if real_02_ts01 is suspended" => sub {
        # Suspending the real_p02_ts01 server
        $app_config->system->mt5->suspend->real->p02_ts01->all(1);

        # Preparing the expected error response
        my $error_response = [{
                'details' => {
                    'account_type' => 'real',
                    'login'        => 'EZR80000000',
                    'server'       => 'p02_ts01',
                    'server_info'  => {
                        'environment' => 'Deriv-Server-02',
                        'geolocation' => {
                            'region'   => 'Africa',
                            'location' => 'South Africa',
                            'sequence' => 2,
                            'group'    => 'africa_derivez'
                        },
                        'id' => 'p02_ts01'
                    },
                },
                'code'    => 'DerivEZAccountInaccessible',
                'message' => 'Deriv EZ is currently unavailable. Please try again later.',
            }];

        # Run the test with exception
        cmp_deeply(exception { $derivez->get_accounts(%params) }, $error_response, 'receive error when get derivez accounts (demo)');

        # Finish test and unsuspeding the server
        $app_config->system->mt5->suspend->real->p02_ts01->all(0);
    };

    $mock_mt5->unmock_all();
};

$app_config->system->mt5->http_proxy->demo->p01_ts04(0);
$app_config->system->mt5->http_proxy->real->p02_ts01(0);

done_testing();
