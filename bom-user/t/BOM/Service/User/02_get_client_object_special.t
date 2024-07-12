use strict;
use warnings;
use Test::More;
use Test::Most;
use Test::FailWarnings;
use Test::Exception;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Customer;
use UUID::Tiny;
use Data::Dumper;

use BOM::Service;
use BOM::Service::Helpers;
use BOM::User;
use BOM::User::Client;

# Mock the BOM::User module
use constant {CACHE_SIZE => 3};

# Disable the tripwires in BOM::Service
my $mock_core = Test::MockModule->new('CORE::GLOBAL');
$mock_core->mock('caller', sub { return 'BOM::Service::ValidNamespace' });

sub init_test {
    $BOM::Service::Helpers::user_object_cache   = Cache::LRU->new(size => CACHE_SIZE);
    $BOM::Service::Helpers::client_object_cache = Cache::LRU->new(size => CACHE_SIZE);
}

subtest 'Check client selection logic for virtual vs duplicate (currency issue)' => sub {
    init_test();
    # We need a bunch of clients to test with.
    my $customer = BOM::Test::Customer->create(
        email_verified => 1,
        clients        => [{
                name        => 'CLIENT1',
                broker_code => 'CR',
            },
            {
                name        => 'CLIENT2',
                broker_code => 'MF',
            },
            {
                name        => 'VRTC',
                broker_code => 'VRTC',
            },
        ]);

    my $client_1 = $customer->get_client_object('CLIENT1');
    my $client_2 = $customer->get_client_object('CLIENT2');

    # Correlation id MUST change otherwise you'll get the cached version

    my $test_client = BOM::Service::Helpers::get_client_object($customer->get_user_id, 'correlation_id_003');
    is $test_client->{broker_code}, 'CR', 'Client CR selected as expected';

    $client_1->status->set('duplicate_account');
    $client_2->status->set('duplicate_account');
    $test_client = BOM::Service::Helpers::get_client_object($customer->get_user_id, 'correlation_id_002');
    is $test_client->{broker_code}, 'VRTC', 'Client VR selected as expected because duplicate account';

    $client_1->status->clear_duplicate_account();
    $client_1->status->set('duplicate_account', 'system', 'Duplicate account - currency change');
    $test_client = BOM::Service::Helpers::get_client_object($customer->get_user_id, 'correlation_id_003');
    is $test_client->{broker_code}, 'CR', 'Client CR selected as expected because duplicate account is currency change';

    # Client2 should now be the preferred client, as it is not a duplicate account
    $client_2->status->clear_duplicate_account();
    $test_client = BOM::Service::Helpers::get_client_object($customer->get_user_id, 'correlation_id_004');
    is $test_client->{broker_code}, 'MF', 'Client MF selected as expected because its the best, not duplicated at all';
};

$mock_core->unmock('caller');

done_testing();
