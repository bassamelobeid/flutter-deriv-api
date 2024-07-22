use strict;
use warnings;
use Test::Most;
use Test::FailWarnings;
use Test::Exception;
use Test::MockModule;
use UUID::Tiny;
use Data::Dumper;

use BOM::Service;
use BOM::Service::Helpers;
use BOM::User;
use BOM::User::Client;

my $mock_user   = Test::MockModule->new('BOM::User');
my $mock_helper = Test::MockModule->new('BOM::Service::Helpers');
my $mock_core   = Test::MockModule->new('CORE::GLOBAL');

my $get_default_client_call_count = 0;    # Reset the counter
my $default_client_exists         = 1;
my $client_count                  = 1;
use constant {CACHE_SIZE => 3};

sub init_test {
    $get_default_client_call_count              = 0;
    $default_client_exists                      = 1;
    $BOM::Service::Helpers::user_object_cache   = Cache::LRU->new(size => CACHE_SIZE);
    $BOM::Service::Helpers::client_object_cache = Cache::LRU->new(size => CACHE_SIZE);
}

# Override the new method to increment $new_call_count every time it's called
$mock_user->mock(
    new => sub {
        my ($class, %args) = @_;
        my $requested_user_id = $args{id};
        return $requested_user_id > 100
            ? undef
            : bless {
            hey_look => 'I am a mock user object',
            id       => $requested_user_id,
            },
            'BOM::User';
    });

$mock_user->mock(
    get_default_client => sub {
        $get_default_client_call_count++;
        return $default_client_exists ? {hey_look => 'I am a mock client object'} : undef;
    });

$mock_user->mock(
    loginids => sub {
        return $client_count;
    });

$mock_helper->mock(
    _get_loginid_count => sub {
        return $client_count;
    });

$mock_core->mock('caller', sub { return 'BOM::Service::ValidNamespace' });

subtest 'Check for exception on non-existent user' => sub {
    init_test();
    throws_ok {
        my $mock = Test::MockModule->new('CORE::GLOBAL');
        $mock->mock('caller', sub { return 'BOM::Service::ValidNamespace' });

        my $client = BOM::Service::Helpers::get_client_object(999, 'correlation_id_001');

        $mock->unmock('caller');
    }
    qr/UserNotFound|::|Could not find a user object.+/, 'get_client_object with non-existent user throws exception';
};

subtest 'Check for exception on non-existent client on existing user' => sub {
    init_test();
    $default_client_exists = 0;
    throws_ok {
        my $mock = Test::MockModule->new('CORE::GLOBAL');
        $mock->mock('caller', sub { return 'BOM::Service::ValidNamespace' });

        my $client = BOM::Service::Helpers::get_client_object(1, 'correlation_id_001');

        $mock->unmock('caller');
    }
    qr/ClientNotFound|::|Could not find a client object.+/, 'get_client_object with no default client throws exception';
};

subtest 'Check two calls for same client with same id and correlation only creates one object' => sub {
    init_test();
    my $client1 = BOM::Service::Helpers::get_client_object(1, 'correlation_id_001');
    is($get_default_client_call_count, 1, 'new called once');
    ok($client1, 'client object returned');

    my $client2 = BOM::Service::Helpers::get_client_object(1, 'correlation_id_001');
    is($get_default_client_call_count, 1, 'new still called once');
    ok($client2, 'client object returned');

    is($client1, $client2, 'same client object returned');
};

subtest 'Check two calls for same client with different correlation id creates two objects' => sub {
    init_test();
    my $client1 = BOM::Service::Helpers::get_client_object(1, 'correlation_id_001');
    is($get_default_client_call_count, 1, 'new called once');
    ok($client1, 'client object returned');

    my $client2 = BOM::Service::Helpers::get_client_object(1, 'correlation_id_002');
    is($get_default_client_call_count, 2, 'new called twice');
    ok($client2, 'client object returned');

    isnt($client1, $client2, 'different client object returned');
};

subtest 'Check two calls with different client and same correlation id creates two objects' => sub {
    init_test();
    my $client1 = BOM::Service::Helpers::get_client_object(1, 'correlation_id_001');
    is($get_default_client_call_count, 1, 'new called once');
    ok($client1, 'client object returned');

    my $client2 = BOM::Service::Helpers::get_client_object(2, 'correlation_id_001');
    is($get_default_client_call_count, 2, 'new called twice');
    ok($client2, 'client object returned');

    isnt($client1, $client2, 'different client object returned');
};

subtest 'Check cache is flushed after CACHE_OBJECT_EXPIRY seconds' => sub {
    init_test();
    my $client1 = BOM::Service::Helpers::get_client_object(1, 'correlation_id_001');
    is($get_default_client_call_count, 1, 'new called once');
    ok($client1, 'client object returned');

    # Reach into the cache and set time back to fake expiry
    $BOM::Service::Helpers::client_object_cache->get('correlation_id_001:1')->{time}->[0] -= BOM::Service::Helpers::CACHE_OBJECT_EXPIRY + 1;

    my $client2 = BOM::Service::Helpers::get_client_object(1, 'correlation_id_001');
    is($get_default_client_call_count, 2, 'new called twice');
    ok($client2, 'client object returned');

    isnt($client1, $client2, 'different client object returned');

};

subtest 'Check cache is flushed thru after CACHE_SIZE calls' => sub {
    init_test();
    my $client1 = BOM::Service::Helpers::get_client_object(1, 'correlation_id_001');
    is($get_default_client_call_count, 1, 'new called once');

    # Fill the cache with CACHE_SIZE clients, LRU cache should bump the first client
    for (my $i = 1; $i <= CACHE_SIZE; $i++) {
        my $disposable_client = BOM::Service::Helpers::get_client_object($i + 10, 'correlation_id_001');
        is($get_default_client_call_count, 1 + $i, 'new called for each client');
        ok($disposable_client, 'client object returned');
    }
    # Original client should now be bumped from the cache
    my $client2 = BOM::Service::Helpers::get_client_object(1, 'correlation_id_001');
    is($get_default_client_call_count, 1 + CACHE_SIZE + 1, 'new called count');
    ok($client2, 'client object returned');

    isnt($client1, $client2, 'different client object returned');
};

subtest 'Check cache is flushed after if number of client accounts changes' => sub {
    init_test();
    my $client = BOM::Service::Helpers::get_client_object(1, 'correlation_id_001');
    is($get_default_client_call_count, 1, 'get_default_client called once');

    $client = BOM::Service::Helpers::get_client_object(1, 'correlation_id_001');
    is($get_default_client_call_count, 1, 'get_default_client called once');

    # Changing the client count should flush cache and we should see a new
    $client_count = 2;
    $client       = BOM::Service::Helpers::get_client_object(1, 'correlation_id_001');
    is($get_default_client_call_count, 2, 'get_default_client called twice');
};

$mock_user->unmock_all();
$mock_helper->unmock_all();
$mock_core->unmock_all();

done_testing();
