use strict;
use warnings;
use Test::Most;
use Test::FailWarnings;

use BOM::Market::DataDecimate;
use File::Slurp;
use BOM::Platform::RedisReplicated;

# This will initialize the redis for check. It is done just to remove dependency of BOM::Feed::FeedRaw. I doubt this change to be correct.
BOM::Platform::RedisReplicated::redis_write()->send_command('restore', 'DECIMATE_frxUSDJPY_31m_FULL',File::Slurp::read_file('t/BOM/Market/DecimateCache/frxUSDJPY.dump'));

my $time  = 1489452136;
my $cache = BOM::Market::DataDecimate->new();
my $rtick = $cache->_get_num_data_from_cache({
        symbol => 'frxUSDJPY',
        num    => 1,
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
