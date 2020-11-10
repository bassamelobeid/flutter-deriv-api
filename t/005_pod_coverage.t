use strict;
use warnings;

use Test::More;
use Test::Pod::CoverageChange;

# This hashref indicates packages which contain sub routines that do not have any POD documentation.
# The number indicates the number of subroutines that are missing POD in the package.
# The number of naked (undocumented) subs should never be increased in this hashref.

my $allowed_naked_packages = {
    'BOM::Event::Listener'                    => 8,
    'BOM::Event::QueueHandler'                => 1,
    'BOM::Event::Services'                    => 9,
    'BOM::Event::Actions::P2P'                => 2,
    'BOM::Event::Actions::Customerio'         => 6,
    'BOM::Event::Actions::CryptoSubscription' => 3,
    'BOM::Event::Actions::MyAffiliate'        => 4,
    'BOM::Event::Actions::Client'             => 26,
    'BOM::Event::Actions::MT5'                => 2,
    'BOM::Event::Actions::CustomerStatement'  => 2,
    'BOM::Event::Services::Track'             => 6,
};

Test::Pod::CoverageChange::pod_coverage_syntax_ok('lib', $allowed_naked_packages);

done_testing();
