use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::Deep;
use BOM::Test::RPC::QueueClient;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Config::Runtime;
use BOM::Platform::Token;
use Date::Utility;

my $c = BOM::Test::RPC::QueueClient->new();

$ENV{LOG_DETAILED_EXCEPTION} = 1;

BOM::Config::Runtime->instance->app_config->system->suspend->wallets(0);

subtest 'legacy accounts' => sub {

    my $user = BOM::User->create(
        email    => 'legacy@test.com',
        password => 'x',
    );

    my $client_vrtc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'VRTC'});
    $client_vrtc->set_default_account('USD');
    $user->add_client($client_vrtc);

    my $params = {language => 'EN'};

    $c->call_ok('account_list', $params)->has_no_system_error->has_error->error_code_is('InvalidToken', 'unauthorized request gets error');

    $params->{token} = BOM::Platform::Token::API->new->create_token($client_vrtc->loginid, 'test');

    my @expected = ({
        account_category     => 'trading',
        account_type         => 'binary',
        broker               => $client_vrtc->broker,
        created_at           => re('\d+'),
        currency             => 'USD',
        currency_type        => 'fiat',
        is_disabled          => bool(0),
        is_virtual           => bool(1),
        landing_company_name => 'virtual',
        linked_to            => [],
        loginid              => $client_vrtc->loginid,
    });

    cmp_deeply($c->call_ok('account_list', $params)->result, bag(@expected), 'expected result for only VRTC account');

    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    $client_cr->set_default_account('EUR');
    $user->add_client($client_cr);

    push @expected,
        {
        account_category     => 'trading',
        account_type         => 'binary',
        broker               => $client_cr->broker,
        created_at           => re('\d+'),
        currency             => 'EUR',
        currency_type        => 'fiat',
        is_disabled          => bool(0),
        is_virtual           => bool(0),
        landing_company_name => 'svg',
        linked_to            => [],
        loginid              => $client_cr->loginid,
        };

    cmp_deeply($c->call_ok('account_list', $params)->result, bag(@expected), 'expected result after adding CR EUR account');

    my $client_disabled = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    $user->add_client($client_disabled);
    $client_disabled->status->set('disabled');

    cmp_deeply($c->call_ok('account_list', $params)->result, bag(@expected), 'disabled account not returned');
};

subtest 'wallets' => sub {
    my $user = BOM::User->create(
        email    => 'wally@test.com',
        password => 'x',
    );

    my $virtual = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'VRW', account_type => 'virtual'});
    $virtual->set_default_account('USD');
    $user->add_client($virtual);

    my $virtual_std = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'VRTC', account_type => 'standard'});
    $virtual_std->set_default_account('USD');
    $user->add_client($virtual_std, $virtual->loginid);

    my %expected = (
        vrw => {
            account_category     => 'wallet',
            account_type         => 'virtual',
            broker               => $virtual->broker,
            created_at           => re('\d+'),
            currency             => 'USD',
            currency_type        => 'fiat',
            is_disabled          => bool(0),
            is_virtual           => bool(1),
            landing_company_name => 'virtual',
            linked_to            => [{
                    loginid  => $virtual_std->loginid,
                    platform => 'dtrade',
                }
            ],
            loginid => $virtual->loginid,
        },
        vrtc => {
            account_category     => 'trading',
            account_type         => 'standard',
            broker               => $virtual_std->broker,
            created_at           => re('\d+'),
            currency             => 'USD',
            currency_type        => 'fiat',
            is_disabled          => bool(0),
            is_virtual           => bool(1),
            landing_company_name => 'virtual',
            linked_to            => [{
                    loginid  => $virtual->loginid,
                    platform => 'dwallet',
                }
            ],
            loginid => $virtual_std->loginid,
        },
    );

    my $params = {
        language => 'EN',
        token    => BOM::Platform::Token::API->new->create_token($virtual->loginid, 'test'),
    };

    cmp_deeply($c->call_ok('account_list', $params)->result, bag(values %expected), 'expected result for virtual wallet and standard');

    my $doughflow = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CRW', account_type => 'doughflow'});
    $doughflow->set_default_account('USD');
    $user->add_client($doughflow);

    my $doughflow_std = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR', account_type => 'standard'});
    $doughflow_std->set_default_account('USD');
    $user->add_client($doughflow_std, $doughflow->loginid);

    $expected{doughflow} = {
        account_category     => 'wallet',
        account_type         => 'doughflow',
        broker               => $doughflow->broker,
        created_at           => re('\d+'),
        currency             => 'USD',
        currency_type        => 'fiat',
        is_disabled          => bool(0),
        is_virtual           => bool(0),
        landing_company_name => 'svg',
        linked_to            => [{
                loginid  => $doughflow_std->loginid,
                platform => 'dtrade',
            }
        ],
        loginid => $doughflow->loginid,
    };

    $expected{doughflow_std} = {
        account_category     => 'trading',
        account_type         => 'standard',
        broker               => $doughflow_std->broker,
        created_at           => re('\d+'),
        currency             => 'USD',
        currency_type        => 'fiat',
        is_disabled          => bool(0),
        is_virtual           => bool(0),
        landing_company_name => 'svg',
        linked_to            => [{
                loginid  => $doughflow->loginid,
                platform => 'dwallet',
            }
        ],
        loginid => $doughflow_std->loginid,
    };

    cmp_deeply($c->call_ok('account_list', $params)->result, bag(values %expected), 'expected result for doughflow wallet and standard');

    my $crypto = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CRW', account_type => 'crypto'});
    $crypto->set_default_account('BTC');
    $user->add_client($crypto);

    my $crypto_std = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR', account_type => 'standard'});
    $crypto_std->set_default_account('BTC');
    $user->add_client($crypto_std, $crypto->loginid);

    $expected{crypto} = {
        account_category     => 'wallet',
        account_type         => 'crypto',
        broker               => $crypto->broker,
        created_at           => re('\d+'),
        currency             => 'BTC',
        currency_type        => 'crypto',
        is_disabled          => bool(0),
        is_virtual           => bool(0),
        landing_company_name => 'svg',
        linked_to            => [{
                loginid  => $crypto_std->loginid,
                platform => 'dtrade',
            }
        ],
        loginid => $crypto->loginid,
    };

    $expected{crypto_std} = {
        account_category     => 'trading',
        account_type         => 'standard',
        broker               => $crypto_std->broker,
        created_at           => re('\d+'),
        currency             => 'BTC',
        currency_type        => 'crypto',
        is_disabled          => bool(0),
        is_virtual           => bool(0),
        landing_company_name => 'svg',
        linked_to            => [{
                loginid  => $crypto->loginid,
                platform => 'dwallet',
            }
        ],
        loginid => $crypto_std->loginid,
    };

    cmp_deeply($c->call_ok('account_list', $params)->result, bag(values %expected), 'expected result for crypto wallet and standard');
};

done_testing();
