use strict;
use warnings;
use Test::More;
use Test::Warnings;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::User;
use BOM::User::Client;
use BOM::Platform::Account::Real::default;

subtest 'Test with no siblings' => sub {
    my ($user) = create_user();
    my $status_list = ['age_verification'];

    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $client_cr->set_default_account('USD');
    $user->add_client($client_cr);

    BOM::Platform::Account::Real::default::copy_status_from_siblings($client_cr, $status_list);

    ok(!$client_cr->status->age_verification, 'age_verification is not set');
};

subtest 'Test with sibling in the same DB, age_verification should not be copied by function' => sub {
    my ($user) = create_user();
    my $status_list = ['age_verification'];

    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $client_cr->set_default_account('USD');
    $user->add_client($client_cr);

    my $client_crw = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $client_crw->set_default_account('BTC');
    $user->add_client($client_crw);

    $client_cr->status->set('age_verification', 'system', 'Reason 1');

    BOM::Platform::Account::Real::default::copy_status_from_siblings($client_crw, $status_list);

    ok(!$client_crw->status->age_verification, 'Status is NOT copied from sibling if they are in the same DB and same landing company');
};

subtest 'Test with sibling in different DB, age_verification should be copied by function' => sub {
    my ($user) = create_user();
    my $status_list = ['age_verification'];

    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $client_cr->set_default_account('USD');
    $user->add_client($client_cr);

    my $client_crw = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CRW',
    });
    $client_crw->set_default_account('USD');
    $user->add_client($client_crw);

    $client_cr->status->set('age_verification', 'system', 'Reason 1');

    BOM::Platform::Account::Real::default::copy_status_from_siblings($client_crw, $status_list);

    ok($client_crw->status->age_verification, 'Status is copied from sibling if they are in diffent DB and same landing company');
};

done_testing();

# Helper function to create a user and client object
my $user_counter = 0;

sub create_user {
    my $user = BOM::User->create(
        email    => 'testuser' . $user_counter++ . '@example.com',
        password => '123',
    );

    my $client_virtual = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });

    $client_virtual->set_default_account('USD');

    $user->add_client($client_virtual);

    return ($user, $client_virtual);
}
