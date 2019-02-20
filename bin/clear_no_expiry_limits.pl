#---------------------------------------------------------
# Purpose: Since we set retelimit keys in two atomic operation(one to set key and other to set TTL), under heavy load it might result of having rate_limit keys without TTL, This script will delete all the rate limit keys that doesnt have TTL set (dont have expiry time)
# Usage:   This script should be set to run as a cron job
#---------------------------------------------------------
use strict;
use warnings;
# load this file to force MOJO::JSON to use JSON::MaybeXS
use Mojo::JSON::MaybeXS;
use DataDog::DogStatsd::Helper;
use Binary::WebSocketAPI::v3::Instance::Redis qw(ws_redis_master);

my $redis = ws_redis_master();

for (@{$redis->keys("rate_limits::*")}) {
    my $exp = $redis->ttl($_);
    if ($exp == -1) {
        #no need to use any tag here
        DataDog::DogStatsd::Helper::stats_inc('bom_websocket_api.v_3.bad_expiry.count');
        $redis->del($_);
    }
}
