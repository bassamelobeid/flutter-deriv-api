
use strict;
use warnings;

use Test::Most;
use Test::FailWarnings;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use BOM::Test::Data::Utility::UnitTestRedis;

use BOM::MarketData qw(create_underlying);
use BOM::Test::Data::Utility::FeedTestDatabase qw( :init );

use BOM::Market::DecimateCache;

#add test case here

done_testing;
