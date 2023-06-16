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

    # Mocking get_user to return the user info from MT5
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

    cmp_deeply(
        $derivez->withdraw(%params),
        {
            status         => 1,
            transaction_id => '212159'
        },
        'can withdraw from derivez to CR'
    );

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

done_testing();
