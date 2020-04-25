use strict;
use warnings;

use Test::MockTime qw(set_fixed_time);
use Test::More;
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_user_transfer_limits);
use BOM::User;
use Date::Utility;
use BOM::Config::Redis;

my $redis = BOM::Config::Redis::redis_replicated_write();

subtest 'transfer limit store' => sub {
    initialize_user_transfer_limits();
    set_fixed_time(Date::Utility->new("2000-01-01")->epoch);

    my $user = BOM::User->create(
        email    => 'user1@test.com',
        password => 'test',
    );

    is $user->daily_transfer_count(), 0, 'no transfers yet';
    $user->daily_transfer_incr();
    is $user->daily_transfer_count(), 1, 'recorded a transfer';
    $user->daily_transfer_incr();
    is $user->daily_transfer_count(), 2, 'recorded another';
    is $redis->ttl('USER_TRANSFERS_DAILY::internal_' . $user->id), 86400, 'key expiry';

    set_fixed_time(86300);    # 100 seconds to midnight

    is $user->daily_transfer_count('mt5'), 0, 'no mt5 transfers yet';
    $user->daily_transfer_incr('mt5');
    is $user->daily_transfer_count('mt5'), 1, 'recorded mt5 transfer';
    is $user->daily_transfer_count(), 2, 'others unaffected';
    is $redis->ttl('USER_TRANSFERS_DAILY::mt5_' . $user->id), 100, 'key expiry';
};

done_testing;
