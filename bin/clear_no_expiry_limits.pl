#---------------------------------------------------------
# Purpose: This script will delete all the rate limit keys that have TTL -1 (dont have expiry time)
# Usage:   This script should be set to run as a cron job
#---------------------------------------------------------
use strict;
use warnings;
use DataDog::DogStatsd::Helper;
use Binary::WebSocketAPI::v3::Instance::Redis qw(ws_redis_master);

my $redis = ws_redis_master();
my @keys = @{$redis->keys("*")};
for (grep /rate_limits::/, @keys) {
    my $exp = $redis->ttl($_);
    if($exp == -1) {
        #no need to use any tag here
        DataDog::DogStatsd::Helper::stats_inc('bom_websocket_api.v_3.bad_expiry.count');
        $redis->del($_);
    }
}
