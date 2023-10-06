use strict;
use warnings;

use Test::More;
use Test::Pod::CoverageChange;

# This hashref indicates packages which contain sub routines that do not have any POD documentation.
# The number indicates the number of subroutines that are missing POD in the package.
# The number of naked (undocumented) subs should never be increased in this hashref.

my $allowed_naked_packages = {
    'BOM::Event::Listener'                              => 10,
    'BOM::Event::Services'                              => 11,
    'BOM::Event::Actions::P2P'                          => 1,
    'BOM::Event::Actions::MyAffiliate'                  => 5,
    'BOM::Event::Actions::Client'                       => 18,
    'BOM::Event::Actions::MT5'                          => 2,
    'BOM::Event::Actions::CustomerStatement'            => 2,
    'BOM::Event::Services::Track'                       => 10,
    'BOM::Event::Actions::Client::IdentityVerification' => 3,
    'BOM::Event::Actions::Anonymization'                => 1,
};

Test::Pod::CoverageChange::pod_coverage_syntax_ok(allowed_naked_packages => $allowed_naked_packages);

done_testing();
