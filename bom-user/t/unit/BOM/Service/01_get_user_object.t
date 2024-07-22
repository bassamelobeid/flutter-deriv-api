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
use Time::HiRes qw(tv_interval gettimeofday);

my $mock_user   = Test::MockModule->new('BOM::User');
my $mock_helper = Test::MockModule->new('BOM::Service::Helpers');
my $mock_core   = Test::MockModule->new('CORE::GLOBAL');

my $new_call_count    = 0;    # Reset the counter
my $requested_user_id = 0;
my $client_count      = 0;

use constant {CACHE_SIZE => 3};

sub init_test {
    $new_call_count                             = 0;
    $requested_user_id                          = 0;
    $client_count                               = 1;
    $BOM::Service::Helpers::user_object_cache   = Cache::LRU->new(size => CACHE_SIZE);
    $BOM::Service::Helpers::client_object_cache = Cache::LRU->new(size => CACHE_SIZE);
}

# Override the new method to increment $new_call_count every time it's called
$mock_user->mock(
    new => sub {
        my ($class, %args) = @_;
        $new_call_count++;
        $requested_user_id = $args{id};
        return $requested_user_id > 100
            ? undef
            : bless {
            hey_look => 'I am a mock user object',
            id       => $requested_user_id,
            },
            'BOM::User';
    });

# Mock the 'loginids' method
$mock_user->mock(
    loginids => sub {
        return $client_count;
    });

$mock_helper->mock(
    _get_loginid_count => sub {
        return $client_count;
    });

# Stop the booby traps going off!!
$mock_core->mock('caller', sub { return 'BOM::Service::ValidNamespace' });

subtest 'Check for exception on non-existent user' => sub {
    init_test();
    throws_ok {
        my $mock = Test::MockModule->new('CORE::GLOBAL');
        $mock->mock('caller', sub { return 'BOM::Service::ValidNamespace' });

        my $user = BOM::Service::Helpers::get_user_object(999, 'correlation_id_001');

        $mock->unmock('caller');
    }
    qr/UserNotFound|::|Could not find a user object.+/, 'get_user_object with non-existent id throws exception';
};

subtest 'Check two calls for same user with same id and correlation only creates one object' => sub {
    init_test();
    my $user1 = BOM::Service::Helpers::get_user_object(1, 'correlation_id_001');
    is($new_call_count,    1, 'new called once');
    is($requested_user_id, 1, 'requested user id is 1');
    ok($user1, 'user object is defined');
    is($user1->{id}, 1, 'user object is correct');

    my $user2 = BOM::Service::Helpers::get_user_object(1, 'correlation_id_001');
    is($new_call_count,    1, 'new still called once');
    is($requested_user_id, 1, 'requested user id is still 1');
    ok($user2, 'user object is defined');

    is($user2->{id}, 1, 'user object is correct');
};

subtest 'Check two calls for same user with different correlation id creates two objects' => sub {
    init_test();
    my $user1 = BOM::Service::Helpers::get_user_object(1, 'correlation_id_001');
    is($new_call_count,    1, 'new called once');
    is($requested_user_id, 1, 'requested user id is 1');
    ok($user1, 'user object is defined');
    is($user1->{id}, 1, 'user object id is correct');

    my $user2 = BOM::Service::Helpers::get_user_object(1, 'correlation_id_002');
    is($new_call_count,    2, 'new called twice');
    is($requested_user_id, 1, 'requested user id is still 1');
    ok($user2, 'user object is defined');
    is($user1->{id}, 1, 'user object id is correct');

    isnt($user1, $user2, 'user objects are different');
};

subtest 'Check two calls with different user and same correlation id creates two objects' => sub {
    init_test();
    my $user1 = BOM::Service::Helpers::get_user_object(1, 'correlation_id_001');
    is($new_call_count,    1, 'new called once');
    is($requested_user_id, 1, 'requested user id is 1');
    ok($user1, 'user object is defined');
    is($user1->{id}, 1, 'user object id is correct');

    my $user2 = BOM::Service::Helpers::get_user_object(2, 'correlation_id_001');
    is($new_call_count,    2, 'new called twice');
    is($requested_user_id, 2, 'requested user id is 2');
    ok($user2, 'user object is defined');
    is($user2->{id}, 2, 'user object id is correct');

    isnt($user1, $user2, 'user objects are different');
};

subtest 'Check cache is flushed after CACHE_OBJECT_EXPIRY seconds' => sub {
    init_test();

    my $user1 = BOM::Service::Helpers::get_user_object(1, 'correlation_id_001');
    is($new_call_count,    1, 'new called once');
    is($requested_user_id, 1, 'requested user id is 1');
    ok($user1, 'user object is defined');
    is($user1->{id}, 1, 'user object id is correct');

    # Reach into the cache and set time back to fake expiry
    $BOM::Service::Helpers::user_object_cache->get('correlation_id_001:1')->{time}->[0] -= BOM::Service::Helpers::CACHE_OBJECT_EXPIRY + 1;

    my $user2 = BOM::Service::Helpers::get_user_object(1, 'correlation_id_001');
    is($new_call_count,    2, 'new called twice');
    is($requested_user_id, 1, 'requested user id is still 1');
    ok($user2, 'user object is defined');
    is($user2->{id}, 1, 'user object id is correct');

    isnt($user1, $user2, 'user objects are different');
};

subtest 'Check cache is flushed thru after CACHE_SIZE calls' => sub {
    init_test();
    my $user = BOM::Service::Helpers::get_user_object(1, 'correlation_id_001');
    is($new_call_count,    1, 'new called once');
    is($requested_user_id, 1, 'requested user id is 1');
    is($user->{id},        1, 'user object id is correct');

    # Fill the cache with CACHE_SIZE users, LRU cache should bump the first user
    for (my $i = 1; $i <= CACHE_SIZE; $i++) {
        my $disposable_user = BOM::Service::Helpers::get_user_object($i + 10, 'correlation_id_001');
        is($new_call_count,    1 + $i,  'new called for each user');
        is($requested_user_id, $i + 10, 'requested user id is correct for each user');
        ok($disposable_user, 'user object is defined');
        is($disposable_user->{id}, $i + 10, 'user object id is correct');
    }
    # Original user should now be bumped from the cache
    my $user2 = BOM::Service::Helpers::get_user_object(1, 'correlation_id_001');
    is($new_call_count,    1 + CACHE_SIZE + 1, 'new called count');
    is($requested_user_id, 1,                  'requested user id is still 1');
    ok($user2, 'user object is defined');
    is($user2->{id}, 1, 'user object id is correct');

    isnt($user, $user2, 'user objects are different');
};

subtest 'Check cache is flushed after if number of client accounts changes' => sub {
    init_test();
    my $user = BOM::Service::Helpers::get_user_object(1, 'correlation_id_001');
    is($new_call_count,    1, 'new called once');
    is($requested_user_id, 1, 'requested user id is 1');
    is($user->{id},        1, 'user object id is correct');

    $user = BOM::Service::Helpers::get_user_object(1, 'correlation_id_001');
    is($new_call_count,    1, 'new called once');
    is($requested_user_id, 1, 'requested user id is 1');
    is($user->{id},        1, 'user object id is correct');

    # Changing the client count should flush cache and we should see a new
    $client_count = 2;
    $user         = BOM::Service::Helpers::get_user_object(1, 'correlation_id_001');
    is($new_call_count,    2, 'new called twice');
    is($requested_user_id, 1, 'requested user id is 1');
    is($user->{id},        1, 'user object id is correct');
};

$mock_user->unmock_all();
$mock_helper->unmock_all();
$mock_core->unmock_all();

done_testing();
