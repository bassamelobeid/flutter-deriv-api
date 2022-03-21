use strict;
use warnings;

use Test::More;
use Test::Warnings;

use BOM::Config::RedisAsync;
use Future::AsyncAwait;

isa_ok BOM::Config::RedisAsync::redis_replicated_write_async()->get, 'Net::Async::Redis', 'redis_replicated_write';

done_testing();
