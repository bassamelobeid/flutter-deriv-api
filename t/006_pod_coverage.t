use strict;
use warnings;

use Test::More;
use Test::Pod::CoverageChange;

# This hashref indicates packages which contain sub routines that do not have any POD documentation.
# The number indicates the number of subroutines that are missing POD in the package.
# The number of naked (undocumented) subs should never be increased in this hashref.

my $allowed_naked_packages = {
    'BOM::Event::Listener'                              => 11,
    'BOM::Event::Services'                              => 11,
    'BOM::Event::Actions::P2P'                          => 2,
    'BOM::Event::Actions::CryptoSubscription'           => 2,
    'BOM::Event::Actions::MyAffiliate'                  => 3,
    'BOM::Event::Actions::Client'                       => 22,
    'BOM::Event::Actions::MT5'                          => 2,
    'BOM::Event::Actions::CustomerStatement'            => 2,
    'BOM::Event::Services::Track'                       => 6,
    'BOM::Event::Actions::Client::IdentityVerification' => 4,
    'BOM::Event::Actions::Common'                       => 2,
    'BOM::Event::Actions::Anonymization'                => 1,
};

Test::Pod::CoverageChange::pod_coverage_syntax_ok(allowed_naked_packages => $allowed_naked_packages);

done_testing();
