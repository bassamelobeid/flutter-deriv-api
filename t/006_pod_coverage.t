use strict;
use warnings;

use Test::More;
use Test::Pod::CoverageChange;

# This hashref indicates packages which contain sub routines that do not have any POD documentation.
# The number indicates the number of subroutines that are missing POD in the package.
# The number of naked (undocumented) subs should never be increased in this hashref.

my $allowed_naked_packages = {
    'BOM::OAuth'               => 1,
    'BOM::OAuth::O'            => 12,
    'BOM::OAuth::OneAll'       => 4,
    'BOM::OAuth::SingleSignOn' => 5,
};

my $ignored_packages = ['BOM::OAuth::SingleSignOn',];

Test::Pod::CoverageChange::pod_coverage_syntax_ok(
    allowed_naked_packages => $allowed_naked_packages,
    ignored_packages       => $ignored_packages
);

done_testing();
