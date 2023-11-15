use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::Deep;
use Test::BOM::RPC::QueueClient;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Event::Emitter;
use BOM::User::WalletMigration;

my $token_model = BOM::Platform::Token::API->new;
my $rpc         = Test::BOM::RPC::QueueClient->new();

$ENV{LOG_DETAILED_EXCEPTION} = 1;

BOM::Config::Runtime->instance->app_config->system->suspend->wallets(0);

my $user_counter = 1;

subtest 'Not eligible state' => sub {
    my $user = BOM::User->create(
        email    => 'testuser' . $user_counter++ . '@example.com',
        password => '123',
    );

    my $client_virtual = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });

    $client_virtual->set_default_account('USD');
    $user->add_client($client_virtual);

    my $vr_token = $token_model->create_token($client_virtual->loginid, 'test token');

    BOM::Config::Runtime->instance->app_config->system->suspend->wallets(1);
    my $res = $rpc->tcall(
        wallet_migration => +{
            token  => $vr_token,
            source => 1,
            args   => {
                wallet_migration => 'state',
            },
        });

    #clean from app_id validation middleware output
    delete $res->{stash};

    cmp_deeply(
        $res,
        +{
            'state' => 'ineligible',
        },
        'Gotex not eligible state'
    );
};

subtest 'Eligible state and plan of migration' => sub {
    my $migration_mock = Test::MockModule->new('BOM::User::WalletMigration');
    $migration_mock->mock(is_eligible => 1);

    subtest 'Virtual only account' => sub {
        my $user = BOM::User->create(
            email    => 'testuser' . $user_counter++ . '@example.com',
            password => '123',
        );

        my $client_virtual = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'VRTC',
        });

        $client_virtual->set_default_account('USD');
        $user->add_client($client_virtual);

        my $vr_token = $token_model->create_token($client_virtual->loginid, 'test token');

        my $res = $rpc->tcall(
            wallet_migration => +{
                token  => $vr_token,
                source => 1,
                args   => {
                    wallet_migration => 'state',
                },
            });

        #clean from app_id validation middleware output
        delete $res->{stash};

        cmp_deeply(
            $res,
            +{
                'state'        => 'eligible',
                'account_list' => bag({
                        'currency'              => 'USD',
                        'landing_company_short' => 'virtual',
                        'platform'              => 'dwallet',
                        'account_category'      => 'wallet',
                        'link_accounts'         => [{
                                'loginid'          => $client_virtual->loginid,
                                'platform'         => 'dtrade',
                                'account_category' => 'trading',
                                'account_type'     => 'standard'
                            }
                        ],
                        'account_type' => 'virtual'
                    })
            },
            'Eligible state and plan of migration for virtual account'
        );
    };

    subtest 'Virtual + Real accounts' => sub {
        my $user = BOM::User->create(
            email    => 'testuser' . $user_counter++ . '@example.com',
            password => '123',
        );

        my $client_virtual = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'VRTC',
        });

        $client_virtual->set_default_account('USD');
        $user->add_client($client_virtual);

        my $cr_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
        $cr_usd->set_default_account('USD');
        $user->add_client($cr_usd);

        my $cr_btc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
        $cr_btc->set_default_account('BTC');
        $user->add_client($cr_btc);

        my $vr_token = $token_model->create_token($client_virtual->loginid, 'test token');

        my $res = $rpc->tcall(
            wallet_migration => +{
                source => 1,
                token  => $vr_token,
                args   => {
                    wallet_migration => 'state',
                },
            });

        #clean from app_id validation middleware output
        delete $res->{stash};

        cmp_deeply(
            $res,
            +{
                'state'        => 'eligible',
                'account_list' => bag(
                    +{
                        account_category      => 'wallet',
                        account_type          => 'crypto',
                        platform              => 'dwallet',
                        currency              => 'BTC',
                        landing_company_short => 'svg',
                        link_accounts         => [
                            +{
                                loginid          => $cr_btc->loginid,
                                account_category => 'trading',
                                account_type     => 'standard',
                                platform         => 'dtrade',
                            }
                        ],
                    },
                    +{
                        account_category      => 'wallet',
                        account_type          => 'doughflow',
                        platform              => 'dwallet',
                        currency              => 'USD',
                        landing_company_short => 'svg',
                        link_accounts         => [
                            +{
                                loginid          => $cr_usd->loginid,
                                account_category => 'trading',
                                account_type     => 'standard',
                                platform         => 'dtrade',
                            }
                        ],
                    },

                    +{
                        account_category      => 'wallet',
                        account_type          => 'virtual',
                        platform              => 'dwallet',
                        currency              => 'USD',
                        landing_company_short => 'virtual',
                        link_accounts         => [
                            +{
                                loginid          => $client_virtual->loginid,
                                account_category => 'trading',
                                account_type     => 'standard',
                                platform         => 'dtrade',
                            }
                        ],
                    },
                ),
            },
            'Eligible state and plan of migration for virtual account'
        );
    }
};

subtest 'Start migration' => sub {
    my $migration_mock = Test::MockModule->new('BOM::User::WalletMigration');
    $migration_mock->mock(is_eligible => 1);

    my $mock_events    = Test::MockModule->new('BOM::Platform::Event::Emitter');
    my @emitted_events = ();
    $mock_events->mock('emit', sub { push @emitted_events, $_[1] });

    my $user = BOM::User->create(
        email    => 'testuser' . $user_counter++ . '@example.com',
        password => '123',
    );

    my $client_virtual = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });

    $client_virtual->set_default_account('USD');
    $user->add_client($client_virtual);

    my $vr_token = $token_model->create_token($client_virtual->loginid, 'test token');

    my $res = $rpc->tcall(
        wallet_migration => +{
            source => 1,
            token  => $vr_token,
            args   => {
                wallet_migration => 'start',
            },
        });

    #clean from app_id validation middleware output
    delete $res->{stash};

    cmp_deeply(
        $res,
        +{
            'state' => 'in_progress',
        },
        'Start migration'
    );

    my $res2 = $rpc->tcall(
        wallet_migration => +{
            source => 1,
            token  => $vr_token,
            args   => {
                wallet_migration => 'state',
            },
        });

    #clean from app_id validation middleware output
    delete $res2->{stash};

    cmp_deeply(
        $res2,
        +{
            'state' => 'in_progress',
        },
        'Migration in progress'
    );

    my $res3 = $rpc->tcall(
        wallet_migration => +{
            source => 1,
            token  => $vr_token,
            args   => {
                wallet_migration => 'start',
            },
        });

    is($res3->{error}{code}, 'MigrationAlreadyInProgress', 'Migration already in progress');

    is(scalar @emitted_events,        1,         'One event emited');
    is($emitted_events[0]->{user_id}, $user->id, 'Migration started for correct user_id');
    is($emitted_events[0]->{app_id},  1,         'Migration started with correct app_id');
};

subtest 'Migration finished' => sub {
    my $migration_mock = Test::MockModule->new('BOM::User::WalletMigration');
    $migration_mock->mock(is_eligible => 1);

    my $user = BOM::User->create(
        email    => 'testuser' . $user_counter++ . '@example.com',
        password => '123',
    );

    my $client_virtual = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });

    $client_virtual->set_default_account('USD');
    $user->add_client($client_virtual);

    my $vr_token = $token_model->create_token($client_virtual->loginid, 'test token');

    BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1
    )->process();

    my $res = $rpc->tcall(
        wallet_migration => +{
            source => 1,
            token  => $vr_token,
            args   => {
                wallet_migration => 'state',
            },
        });

    #clean from app_id validation middleware output
    delete $res->{stash};

    cmp_deeply(
        $res,
        +{
            'state' => 'migrated',
        },
        'Migration finished'
    );
};

done_testing();
