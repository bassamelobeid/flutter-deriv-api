use strict;
use warnings;

use Test::Most;
use Test::FailWarnings;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Market::TickCache;

new_ok('BOM::Market::TickCache');

my $at = BOM::Market::TickCache->new;

is($at->retention_interval->seconds, 7200, 'Default retention interval is 7200 seconds');

$at = BOM::Market::TickCache->new({
    retention_interval => '1h',
});
is($at->retention_interval->seconds, 3600, '1h retention interval is 3600 seconds');

done_testing;
