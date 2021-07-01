use strict;
use warnings;

use Test::More;
use Test::Pod::CoverageChange;

# This hashref indicates packages which contain sub routines that do not have any POD documentation.
# The number indicates the number of subroutines that are missing POD in the package.
# The number of naked (undocumented) subs should never be increased in this hashref.

my $allowed_naked_packages = {
    'BOM::RPC'                              => 1,
    'BOM::RPC::Registry'                    => 2,
    'BOM::RPC::Transport::Redis'            => 1,
    'BOM::RPC::Feed::Reader'                => 5,
    'BOM::RPC::Feed::Tick'                  => 11,
    'BOM::RPC::Feed::Sendfile'              => 4,
    'BOM::RPC::Feed::Writer'                => 11,
    'BOM::RPC::v3::CopyTrading'             => 0,
    'BOM::RPC::v3::P2P'                     => 2,
    'BOM::RPC::v3::Transaction'             => 6,
    'BOM::RPC::v3::Contract'                => 4,
    'BOM::RPC::v3::Static'                  => 1,
    'BOM::RPC::v3::MarketData'              => 1,
    'BOM::RPC::v3::Accounts'                => 5,
    'BOM::RPC::v3::PortfolioManagement'     => 2,
    'BOM::RPC::v3::NewAccount'              => 6,
    'BOM::RPC::v3::Cashier'                 => 13,
    'BOM::RPC::v3::Services'                => 2,
    'BOM::RPC::v3::Utility'                 => 16,
    'BOM::RPC::v3::EmailVerification'       => 1,
    'BOM::RPC::v3::TickStreamer'            => 3,
    'BOM::RPC::v3::Debug'                   => 0,
    'BOM::RPC::v3::DocumentUpload'          => 6,
    'BOM::RPC::v3::Authorize'               => 2,
    'BOM::RPC::v3::App'                     => 2,
    'BOM::RPC::v3::MarketDiscovery'         => 1,
    'BOM::RPC::v3::MT5::Account'            => 19,
    'BOM::RPC::v3::CopyTrading::Statistics' => 1,
};

Test::Pod::CoverageChange::pod_coverage_syntax_ok(allowed_naked_packages => $allowed_naked_packages);

done_testing();
