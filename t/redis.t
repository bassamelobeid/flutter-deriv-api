use strict;
use warnings;

use Test::More tests => 3;
use Test::Warnings;

subtest 'using RedisReplicated (pending deprecation)' => sub {
    plan tests => 4;

    use BOM::Config::RedisReplicated;

    my ($read, $write);

    like Test::Warnings::warning { $read = BOM::Config::RedisReplicated::redis_read() },
        qr/redis_read is DEPRECATED in favor of BOM::Config::Redis::redis_replicated_read/;
    isa_ok $read, 'RedisDB';

    like Test::Warnings::warning { $write = BOM::Config::RedisReplicated::redis_write() },
        qr/redis_write is DEPRECATED in favor of BOM::Config::Redis::redis_replicated_write/;
    isa_ok $write, 'RedisDB';
};

subtest 'using Redis' => sub {
    plan tests => 2;

    use BOM::Config::Redis;

    isa_ok BOM::Config::Redis::redis_replicated_read(), 'RedisDB';
    isa_ok BOM::Config::Redis::redis_replicated_write(), 'RedisDB';
};
