use strict;
use warnings;
use Test::More;

use BOM::Config::Redis ();
use BOM::Test::Helper::Redis 'is_within_threshold';

my @redis = qw(redis_replicated_read redis_replicated_write redis_pricer);

for my $server (@redis) {
    my $redis = BOM::Config::Redis->can($server)->();

    is_within_threshold $server, $redis->info();
}

done_testing;
