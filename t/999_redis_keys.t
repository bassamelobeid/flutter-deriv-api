use strict;
use warnings;
use Test::More;

use Binary::WebSocketAPI::v3::Instance::Redis ();
use BOM::Test::Helper::Redis 'is_within_threshold';

my @redis = qw(redis_feed_master redis_pricer  redis_pricer_subscription);

for my $server (@redis) {
    my $redis = Binary::WebSocketAPI::v3::Instance::Redis->can($server)->();

    is_within_threshold $server, $redis->backend->info('keyspace');
}

done_testing;
