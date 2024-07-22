use strict;
use warnings;

use Test::More;
use Test::Warnings qw(warning);
use Test::Fatal;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Customer;

use BOM::Event::Actions::Wallets;
use BOM::User::WalletMigration;
use BOM::User;

my $service_contexts = BOM::Test::Customer::get_service_contexts();

subtest wallet_migration_started => sub {
    my $user = BOM::User->create(
        email    => 'testuser@example.com',
        password => '123',
    );

    my $client_virtual = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });

    $client_virtual->set_default_account('USD');

    $user->add_client($client_virtual);

    BOM::Event::Actions::Wallets::wallet_migration_started({
            user_id => $user->id,
            app_id  => 1
        },
        $service_contexts
    )->get;

    my $migration = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1
    );

    is($migration->state, 'migrated', 'Migration in done');
};

subtest "Should be able to continue migration if fail to migrate loginid" => sub {

    my $mock_user = Test::MockModule->new('BOM::User');
    $mock_user->mock('migrate_loginid', sub { die 'migrate failed' });

    my $user = BOM::User->create(
        email    => 'testuser1@example.com',
        password => '123',
    );

    my $client_virtual = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });

    $client_virtual->set_default_account('USD');

    $user->add_client($client_virtual);

    eval { BOM::Event::Actions::Wallets::wallet_migration_started({user_id => $user->id, app_id => 1}, $service_contexts)->get };

    my $migration = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1
    );

    is($migration->state, 'in_progress', 'Migration is failed and waiting for retry');

    $mock_user->unmock('migrate_loginid');

    BOM::Event::Actions::Wallets::wallet_migration_started({
            user_id => $user->id,
            app_id  => 1
        },
        $service_contexts
    )->get;

    $migration = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1
    );

    is($migration->state, 'migrated', 'Migration in done');
};

subtest "Should be able to continue migration if fail to update account type" => sub {
    my $user = BOM::User->create(
        email    => 'testuser2@example.com',
        password => '123',
    );

    my $client_virtual = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });

    $client_virtual->set_default_account('USD');

    $user->add_client($client_virtual);

    my $mock_user = Test::MockModule->new('BOM::User::Client');
    $mock_user->mock('save', sub { die 'fail to save client' });

    eval { BOM::Event::Actions::Wallets::wallet_migration_started({user_id => $user->id, app_id => 1}, $service_contexts)->get };

    my $migration = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1
    );

    is($migration->state, 'in_progress', 'Migration is failed and waiting for retry');

    $mock_user->unmock('save');

    BOM::Event::Actions::Wallets::wallet_migration_started({
            user_id => $user->id,
            app_id  => 1
        },
        $service_contexts
    )->get;

    $migration = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1
    );

    is($migration->state, 'migrated', 'Migration in done');
};

subtest "Should be able to continue migration if fail to create wallet account" => sub {
    my $user = BOM::User->create(
        email    => 'testuser3@example.com',
        password => '123',
    );

    my $client_virtual = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });

    $client_virtual->set_default_account('USD');

    $user->add_client($client_virtual);

    my $mock_user = Test::MockModule->new('BOM::User::WalletMigration');
    $mock_user->mock('create_wallet', sub { die 'fail to save client' });

    eval { BOM::Event::Actions::Wallets::wallet_migration_started({user_id => $user->id, app_id => 1}, $service_contexts)->get };

    my $migration = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1
    );

    is($migration->state, 'in_progress', 'Migration is failed and waiting for retry');

    $mock_user->unmock('create_wallet');

    BOM::Event::Actions::Wallets::wallet_migration_started({
            user_id => $user->id,
            app_id  => 1
        },
        $service_contexts
    )->get;

    $migration = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1
    );

    is($migration->state, 'migrated', 'Migration in done');
};

done_testing();
