#!/etc/rmg/bin/perl

use strict;
use warnings;

use BOM::Product::Contract::PredefinedParameters qw(update_predefined_highlow);
use Cache::RedisDB;
use JSON qw(from_json);

#Update high and low of symbols for predefined periods.

my @symbols = BOM::Product::Contract::PredefinedParameters::supported_symbols;
@symbols = ('frxUSDJPY');
my $redis = Cache::RedisDB->redis;

$redis->subscription_loop(
    subscribe        => [map { 'FEED::' . $_ } @symbols],
    default_callback => sub {
        my $tick_data = from_json($_[3]);
        update_predefined_highlow($tick_data);
    },
);
