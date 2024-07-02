use strict;
use warnings;

use Test::Fatal;
use Test::More;
use Test::Deep;
use Test::Future;
use Test::MockModule;

use BOM::MT5::User::Cached;
use JSON::MaybeXS;

my $mock_mt5_api = Test::MockModule->new('BOM::MT5::User::Async');
my $mock_redis   = Test::MockModule->new('RedisDB');
my $mock_module  = Test::MockModule->new('BOM::MT5::User::Cached');
my $mt5_loginid  = 'MTR12345';
my $mt5_user     = {
    login    => 12345,
    balance  => 1000,
    currency => 'USD',
    group    => 'real\p01_ts01\synthetic\svg_std_usd',
    comment  => 'Test User',
};

my ($api_timestamp, $timestamp_from_redis);

$mock_module->redefine(_initiate_new_redis_instance => sub { return RedisDB->new() });
$mock_mt5_api->redefine(
    get_user => sub {
        my $loginid = shift;
        return Future->done($mt5_user);
    });

subtest 'First request done through API' => sub {
    my $set_cache;
    $mock_redis->redefine(
        set => sub {
            my ($self, $key, $value) = @_;
            $set_cache = decode_json($value);
            return;
        });

    cmp_deeply BOM::MT5::User::Cached::get_user_cached($mt5_loginid)->then(
        sub {
            my $user = shift;
            $api_timestamp = delete $user->{request_timestamp};
            ok $api_timestamp, 'Request timestamp is set';
            return $user;
        }
    )->else(
        sub {
            my $error = shift;
            fail "Failed to get user: $error";
        })->get(), $mt5_user, 'API User matches';

    cmp_deeply $set_cache, {%$mt5_user, request_timestamp => $api_timestamp}, 'Cache is set';
};

subtest 'Second request done through Redis' => sub {
    $mock_redis->redefine(
        get => sub {
            return encode_json({%$mt5_user, request_timestamp => $api_timestamp});
        });

    $mock_mt5_api->redefine(
        get_user => sub {
            fail "API should not be called";
            return;
        });

    $mock_redis->redefine(
        set => sub {
            fail "Should not set again";
            return;
        });

    cmp_deeply BOM::MT5::User::Cached::get_user_cached($mt5_loginid)->then(
        sub {
            my $user = shift;
            $timestamp_from_redis = delete $user->{request_timestamp};
            ok $timestamp_from_redis, 'Request timestamp is set';
            return $user;
        }
    )->else(
        sub {
            my $error = shift;
            fail "Failed to get user: $error";
        })->get(), $mt5_user, 'Redis User matches';
    is $api_timestamp, $timestamp_from_redis, 'Request timestamp matches';
};

subtest 'Invalidating cache' => sub {
    my $cache_invalidated = 0;
    $mock_redis->redefine(
        set => sub {
            return undef;
        },
        get => sub {
            return undef;
        },
        del => sub {
            $cache_invalidated = 1;
            return undef;
        });

    $mock_mt5_api->redefine(
        get_user => sub {
            return Future->done($mt5_user);
        });

    BOM::MT5::User::Cached::invalidate_mt5_api_cache($mt5_loginid);
    cmp_deeply BOM::MT5::User::Cached::get_user_cached($mt5_loginid)->then(
        sub {
            my $user = shift;
            $api_timestamp = delete $user->{request_timestamp};
            return $user;
        }
    )->else(
        sub {
            my $error = shift;
            fail "Failed to get user: $error";
        })->get(), $mt5_user, 'User matches';
    ok $cache_invalidated, 'Cache invalidated';
    ok($api_timestamp != $timestamp_from_redis), 'Request timestamp does not match previous request';
};

subtest 'Redis get error' => sub {
    my $current_time = time;
    $mock_redis->redefine(
        get => sub {
            die 'Redis get error';
        });

    cmp_deeply BOM::MT5::User::Cached::get_user_cached($mt5_loginid)->then(
        sub {
            my $user = shift;
            $api_timestamp = delete $user->{request_timestamp};
            return $user;
        }
    )->else(
        sub {
            my $error = shift;
            return $error;
        })->get(), $mt5_user, 'Redis get error is caught, API response returned';

    ok $api_timestamp >= $current_time, 'New request timestamp is set';
};

subtest 'Redis instance error' => sub {
    my $current_time = time;
    $mock_module->redefine(
        _initiate_new_redis_instance => sub {
            die 'Redis instance error';
        });

    cmp_deeply BOM::MT5::User::Cached::get_user_cached($mt5_loginid)->then(
        sub {
            my $user = shift;
            $api_timestamp = delete $user->{request_timestamp};
            return $user;
        }
    )->else(
        sub {
            my $error = shift;
            return $error;
        })->get(), $mt5_user, 'Redis instance error caught, API response returned';

    ok $api_timestamp >= $current_time, 'New request timestamp is set';
    $mock_module->unmock_all;
    $mock_redis->unmock_all;
};

subtest 'API returns NotFound' => sub {

    $mock_mt5_api->redefine(
        get_user => sub {
            my $loginid = shift;
            return Future->done({'code' => 'NotFound', 'error' => 'ERR_NOTFOUND'});
        });

    $mock_redis->redefine(
        get => sub {
            return undef;
        });

    $mock_redis->redefine(
        set => sub {
            fail "Redis should not be set";
            return;
        });

    cmp_deeply
        BOM::MT5::User::Cached::get_user_cached($mt5_loginid)->get,
        {
        'code'  => 'NotFound',
        'error' => 'ERR_NOTFOUND'
        },
        'NotFound Response from API';
};

done_testing;
