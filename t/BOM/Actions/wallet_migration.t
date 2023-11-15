use strict;
use warnings;

use Test::More;
use Test::Warnings qw(warning);
use Test::Fatal;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use BOM::Event::Actions::Wallets;
use BOM::User::WalletMigration;
use BOM::User;

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

    BOM::Event::Actions::Wallets::wallet_migration_started({user_id => $user->id, app_id => 1});

    my $migration = BOM::User::WalletMigration->new(
        user   => $user,
        app_id => 1
    );

    is($migration->state, 'migrated', 'Migration in done');

};

done_testing();
