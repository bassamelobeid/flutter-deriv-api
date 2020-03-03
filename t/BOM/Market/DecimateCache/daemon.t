use strict;
use warnings;
use Test::Most;
use Test::FailWarnings;
use BOM::Market::DataDecimate;
use BOM::Config::Runtime;

BOM::Config::Runtime->instance->app_config;

my $time = time;

my $redis     = BOM::Config::Redis::redis_replicated_write();
my $undec_key = "DECIMATE_frxUSDJPY" . "_31m_FULL";
my $encoder   = Sereal::Encoder->new({
    canonical => 1,
});
my %defaults = (
    symbol => 'frxUSDJPY',
    epoch  => $time,
    quote  => '108.222',
    bid    => '108.223',
    ask    => '108.224',
    count  => 1,
);
$redis->zadd($undec_key, $defaults{epoch}, $encoder->encode(\%defaults));

my $cache = BOM::Market::DataDecimate->new({market => 'forex'});

my $rtick = $cache->_get_num_data_from_cache({
    symbol    => 'frxUSDJPY',
    num       => 1,
    end_epoch => $time,
});

eq_or_diff $rtick->[0],
    {
    epoch  => $time,
    symbol => 'frxUSDJPY',
    quote  => '108.222',
    bid    => '108.223',
    ask    => '108.224',
    count  => 1,
    },
    "cache was updated";

done_testing;
