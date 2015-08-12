use strict;
use warnings;

use Test::Most;
use Test::FailWarnings;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Market::AggTicks;

new_ok('BOM::Market::AggTicks');

my $at = BOM::Market::AggTicks->new;

is($at->agg_interval->seconds,             15,     'Default aggregation interval is 15 seconds');
is($at->returns_interval->seconds,         60,     'Default returns interval is 60 seconds');
is($at->annualization,                     362880, 'Default annualization is 362880');
is($at->unagg_retention_interval->seconds, 900,    'Default unaggregated retention interval is 15 minutes');
is($at->agg_retention_interval->seconds,   43200,  'Default aggregated retention interval is 43200 seconds');

note("We demand the ratio of returns_interval and agg_interval is an integer inside our bounds. These ratio bounds are not runtime configurable.");
throws_ok {
    $at = BOM::Market::AggTicks->new({
        agg_interval     => '1m1s',
        returns_interval => '5m',
    });
}
qr/type constraint.*Int/;

throws_ok {
    $at = BOM::Market::AggTicks->new({
        agg_interval     => '-1m',
        returns_interval => '5m',
    });
}
qr/is not an integer between/;

throws_ok {
    $at = BOM::Market::AggTicks->new({
        agg_interval     => '1s',
        returns_interval => '5m',
    });
}
qr/is not an integer between/;

done_testing;
