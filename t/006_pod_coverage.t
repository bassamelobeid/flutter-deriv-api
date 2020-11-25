use strict;
use warnings;

use Test::More;
use Test::Pod::CoverageChange;

# This hashref indicates packages which contain sub routines that do not have any POD documentation.
# The number indicates the number of subroutines that are missing POD in the package.
# The number of naked (undocumented) subs should never be increased in this hashref.

my $allowed_naked_packages = {
    'BOM::Config'                         => 41,
    'BOM::Config::Redis'                  => 1,
    'BOM::Config::RedisTransactionLimits' => 2,
    'BOM::Config::Runtime'                => 4,
    'BOM::Config::Chronicle'              => 3,
    'BOM::Config::Quants'                 => 6,
    'BOM::Config::CurrencyConfig'         => 2,
    'BOM::Config::QuantsConfig'           => 7,
};

Test::Pod::CoverageChange::pod_coverage_syntax_ok('lib', $allowed_naked_packages);

done_testing();
