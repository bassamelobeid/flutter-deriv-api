use strict;
use warnings;

use Test::More;
use Test::Warnings;

use BOM::Config::Redis;

isa_ok BOM::Config::Redis::redis_replicated_read(),           'RedisDB', 'redis_replicated_read';
isa_ok BOM::Config::Redis::redis_replicated_write(),          'RedisDB', 'redis_replicated_write';
isa_ok BOM::Config::Redis::redis_pricer(),                    'RedisDB', 'redis_pricer';
isa_ok BOM::Config::Redis::redis_pricer_subscription_write(), 'RedisDB', 'redis_pricer_subscription_write';
isa_ok BOM::Config::Redis::redis_pricer_shared(),             'RedisDB', 'redis_pricer_shared';
isa_ok BOM::Config::Redis::redis_pricer_shared_write(),       'RedisDB', 'redis_pricer_shared_write';
isa_ok BOM::Config::Redis::redis_feed_master(),               'RedisDB', 'redis_feed_master';
isa_ok BOM::Config::Redis::redis_feed_master_write(),         'RedisDB', 'redis_feed_master_write';
isa_ok BOM::Config::Redis::redis_feed(),                      'RedisDB', 'redis_feed';
isa_ok BOM::Config::Redis::redis_feed_write(),                'RedisDB', 'redis_feed_write';
isa_ok BOM::Config::Redis::redis_mt5_user(),                  'RedisDB', 'redis_mt5_user';
isa_ok BOM::Config::Redis::redis_mt5_user_write(),            'RedisDB', 'redis_mt5_user_write';
isa_ok BOM::Config::Redis::redis_events(),                    'RedisDB', 'redis_events';
isa_ok BOM::Config::Redis::redis_events_write(),              'RedisDB', 'redis_events_write';
isa_ok BOM::Config::Redis::redis_transaction(),               'RedisDB', 'redis_transaction';
isa_ok BOM::Config::Redis::redis_transaction_write(),         'RedisDB', 'redis_transaction_write';
isa_ok BOM::Config::Redis::redis_auth(),                      'RedisDB', 'redis_auth';
isa_ok BOM::Config::Redis::redis_auth_write(),                'RedisDB', 'redis_auth_write';
isa_ok BOM::Config::Redis::redis_expiryq(),                   'RedisDB', 'redis_expiryq';
isa_ok BOM::Config::Redis::redis_expiryq_write(),             'RedisDB', 'redis_expiryq_write';
isa_ok BOM::Config::Redis::redis_p2p(),                       'RedisDB', 'redis_p2p';
isa_ok BOM::Config::Redis::redis_p2p_write(),                 'RedisDB', 'redis_p2p_write';
isa_ok BOM::Config::Redis::redis_ws(),                        'RedisDB', 'redis_ws';
isa_ok BOM::Config::Redis::redis_ws_write(),                  'RedisDB', 'redis_ws_write';
isa_ok BOM::Config::Redis::redis_payment(),                   'RedisDB', 'redis_payment';
isa_ok BOM::Config::Redis::redis_payment_write(),             'RedisDB', 'redis_payment_write';

# redis_rpc not working on circleci now. need special redis v6 instance
# seems not really in use, so we ignore those 2 tests for now.
# isa_ok BOM::Config::Redis::redis_rpc(),                       'RedisDB', 'redis_rpc';
# isa_ok BOM::Config::Redis::redis_rpc_write(),                 'RedisDB', 'redis_rpc_write';

ok BOM::Config::Redis::redis_config('feed', 'read'), 'redis_config';

subtest 'deprecated redis_read/redis_write' => sub {
    plan tests => 4;

    my ($read, $write);

    like Test::Warnings::warning { $read = BOM::Config::Redis::redis_read() },
        qr/redis_read is DEPRECATED in favor of BOM::Config::Redis::redis_replicated_read/;
    isa_ok $read, 'RedisDB';

    like Test::Warnings::warning { $write = BOM::Config::Redis::redis_write() },
        qr/redis_write is DEPRECATED in favor of BOM::Config::Redis::redis_replicated_write/;
    isa_ok $write, 'RedisDB';
};

done_testing();
