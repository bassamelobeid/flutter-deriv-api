use strict;
use warnings;
use Test::More;
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis    qw(initialize_user_transfer_limits);
use BOM::User;
use Date::Utility;
use BOM::Config::Redis;

my $redis = BOM::Config::Redis::redis_replicated_write();

subtest 'transfer limit store' => sub {
    initialize_user_transfer_limits();

    my $user = BOM::User->create(
        email    => 'user1@test.com',
        password => 'test',
    );

    is $user->daily_transfer_count(), 0, 'no transfers yet';
    $user->daily_transfer_incr();
    is $user->daily_transfer_count(), 1, 'recorded a transfer';
    $user->daily_transfer_incr();
    is $user->daily_transfer_count(), 2, 'recorded another';
    cmp_ok $redis->ttl('USER_TRANSFERS_DAILY::internal_' . $user->id), '<=', 86400, 'key expiry';

    is $user->daily_transfer_count('MT5'), 0, 'no mt5 transfers yet';
    $user->daily_transfer_incr({type => 'MT5'});
    is $user->daily_transfer_count('MT5'), 1, 'recorded mt5 transfer';
    is $user->daily_transfer_count(),      2, 'others unaffected';

    cmp_ok $redis->ttl('USER_TRANSFERS_DAILY::MT5_' . $user->id), '<=', Date::Utility->new->epoch, 'key expiry';
};

subtest 'transfer amount limit store' => sub {
    initialize_user_transfer_limits();
    BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->daily_cumulative_limit->enable(1);

    my $user = BOM::User->create(
        email    => 'user_amount_1@test.com',
        password => 'test',
    );

    is $user->daily_transfer_amount(), 0, 'no transfers yet';
    $user->daily_transfer_incr({amount => 1000});
    is $user->daily_transfer_amount(), 1000, 'recorded a transfer';
    $user->daily_transfer_incr({amount => 2000});
    is $user->daily_transfer_amount(), 3000, 'recorded another';
    cmp_ok $redis->ttl('USER_TOTAL_AMOUNT_TRANSFERS_DAILY::' . Date::Utility->new->date), '<=', 86400, 'key expiry';

    is $user->daily_transfer_amount('MT5'), 0, 'no mt5 transfers yet';
    $user->daily_transfer_incr({
        type   => 'MT5',
        amount => 5000
    });
    is $user->daily_transfer_amount('MT5'), 5000, 'recorded mt5 transfer';
    is $user->daily_transfer_amount(),      3000, 'others unaffected';
    cmp_ok $redis->ttl('USER_TOTAL_AMOUNT_TRANSFERS_DAILY::' . Date::Utility->new->date), '<=', Date::Utility->new->epoch, 'key expiry';
};

done_testing;
