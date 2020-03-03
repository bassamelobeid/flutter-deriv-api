use strict;
use warnings;

use Test::More tests => 4;
use Test::Warnings;

use BOM::Config::Redis;

isa_ok BOM::Config::Redis::redis_replicated_read(),  'RedisDB';
isa_ok BOM::Config::Redis::redis_replicated_write(), 'RedisDB';

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
