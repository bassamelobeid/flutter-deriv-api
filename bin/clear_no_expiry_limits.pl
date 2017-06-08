use strict;
use warnings;
use DataDog::DogStatsd::Helper;
use Binary::WebSocketAPI::v3::Instance::Redis qw(ws_redis_master);

my $redis = ws_redis_master();
my @keys = @{$redis->keys("*")};
for (grep /rate_limits::/, @keys) {
    my $exp = $redis->ttl($_);
    if($exp == -1) {
        #what tag to use, I removed tag as i think that we only need to know how many times this is happening.
        DataDog::DogStatsd::Helper::stats_inc('bom_websocket_api.v_3.bad_expiry.count');
        $redis->del($_);
    }
}
