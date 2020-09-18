use strict;
use warnings;

use Test::More;
use Test::Pod::CoverageChange;

# This hashref indicates packages which contain sub routines that do not have any POD documentation.
# The number indicates the number of subroutines that are missing POD in the package.
# The number of naked (undocumented) subs should never be increased in this hashref.

my $allowed_naked_packages = {
    'BOM::Pricing::PriceDaemon'    => 9,
    'BOM::Pricing::v3::Contract'   => 13,
    'BOM::Pricing::v3::MarketData' => 8,
    'BOM::Pricing::v3::Utility'    => 2,
};

Test::Pod::CoverageChange::pod_coverage_syntax_ok('lib', $allowed_naked_packages);

done_testing();
