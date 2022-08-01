use strict;
use warnings;

use Test::More;
use Test::Pod::CoverageChange;

# This hashref indicates packages which contain sub routines that do not have any POD documentation.
# The number indicates the number of subroutines that are missing POD in the package.
# The number of naked (undocumented) subs should never be increased in this hashref.

my $allowed_naked_packages = {
    'BOM::Config'                         => 3,
    'BOM::Config::Redis'                  => 1,
    'BOM::Config::RedisTransactionLimits' => 2,
    'BOM::Config::Runtime'                => 2,
    'BOM::Config::Chronicle'              => 1,
    'BOM::Config::Quants'                 => 1,
    'BOM::Config::QuantsConfig'           => 7,
    'BOM::Config::AccountType'            => 14,
    'BOM::Config::AccountType::Category'  => 8,
    'BOM::Config::AccountType::Group'     => 5,
};

Test::Pod::CoverageChange::pod_coverage_syntax_ok(allowed_naked_packages => $allowed_naked_packages);

done_testing();
