use strict;
use warnings;

use Test::More;
use Test::Pod::CoverageChange;

# This hashref indicates packages which contain sub routines that do not have any POD documentation.
# The number indicates the number of subroutines that are missing POD in the package.
# The number of naked (undocumented) subs should never be increased in this hashref.

my $allowed_naked_packages = {
    'BOM::MyAffiliates'                            => 4,
    'BOM::MyAffiliatesApp'                         => 1,
    'BOM::MyAffiliates::BackfillManager'           => 4,
    'BOM::MyAffiliates::Reporter'                  => 16,
    'BOM::MyAffiliates::GenerateRegistrationDaily' => 12,
    'BOM::MyAffiliates::ActivityReporter'          => 3,
    'BOM::MyAffiliates::PaymentToAccountManager'   => 8,
    'BOM::MyAffiliates::TurnoverReporter'          => 3,
    'BOM::MyAffiliates::MultiplierReporter'        => 4,
    'BOM::MyAffiliatesApp::Controller'             => 6,
};

Test::Pod::CoverageChange::pod_coverage_syntax_ok('lib', $allowed_naked_packages);

done_testing();
