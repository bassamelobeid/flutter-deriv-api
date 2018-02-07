use strict;
use warnings;
use Test::More;

use BOM::Platform::RedisReplicated ();
use BOM::Test::Helper::Redis 'is_within_threshold';

my @redis = qw(redis_read redis_write redis_pricer);

for my $server (@redis) {
    my $redis = BOM::Platform::RedisReplicated->$server();

    is_within_threshold $server, $redis->info();
}

done_testing;
