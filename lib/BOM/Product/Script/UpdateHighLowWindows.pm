package BOM::Product::Script::UpdateHighLowWindows;
use strict;
use warnings;

use LandingCompany::Registry;
use BOM::Platform::Runtime;
use BOM::Product::Contract::PredefinedParameters qw(update_predefined_highlow);
use Cache::RedisDB;
use JSON::MaybeXS;

#Update high and low of symbols for predefined periods.
sub run {
    my $offerings_obj = LandingCompany::Registry::get('japan')->multi_barrier_offerings(BOM::Platform::Runtime->instance->get_offerings_config);
    my @symbols       = $offerings_obj->values_for_key('underlying_symbol');

    my $redis = Cache::RedisDB->redis;

    $redis->subscription_loop(
        subscribe        => [map { 'FEED_LATEST_TICK::' . $_ } @symbols],
        default_callback => sub {
            my $tick_data = JSON::MaybeXS->new->decode($_[3]);
            update_predefined_highlow($tick_data);
        },
    );
    return;
}

1;
