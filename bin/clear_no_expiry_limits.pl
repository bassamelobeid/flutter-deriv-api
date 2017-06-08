use strict;
use warnings;
use DataDog::DogStatsd::Helper;
use Binary::WebSocketAPI::v3::Instance::Redis qw(ws_redis_master);

my $redis = ws_redis_master();
my @keys = @{$redis->keys("*")};
for (grep /rate_limits::/, @keys) {
    my $exp = $redis->ttl($_);
    if($exp == -1) {
        DataDog::DogStatsd::Helper::stats_inc('bom_websocket_api.v_3.bad_expiry.count',
                {tags => ['tag:'   ]}); #what tag to use.
        $redis->del($_);
    }
}
