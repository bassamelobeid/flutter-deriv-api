use strict;
use warnings;

use Test::More;
use Test::Pod::CoverageChange;

# This hashref indicates packages which contain sub routines that do not have any POD documentation.
# The number indicates the number of subroutines that are missing POD in the package.
# The number of naked (undocumented) subs should never be increased in this hashref.

my $allowed_naked_packages = {
    'Binary::WebSocketAPI'                                                 => 2,
    'Binary::WebSocketAPI::Hooks'                                          => 27,
    'Binary::WebSocketAPI::BalanceConnections'                             => 2,
    'Binary::WebSocketAPI::Actions'                                        => 1,
    'Binary::WebSocketAPI::Plugins::Introspection'                         => 3,
    'Binary::WebSocketAPI::Plugins::Longcode'                              => 1,
    'Binary::WebSocketAPI::Plugins::Helpers'                               => 1,
    'Binary::WebSocketAPI::Plugins::RateLimits'                            => 5,
    'Binary::WebSocketAPI::v3::SubscriptionManager'                        => 6,
    'Binary::WebSocketAPI::v3::Subscription'                               => 4,
    'Binary::WebSocketAPI::v3::Instance::Redis'                            => 9,
    'Binary::WebSocketAPI::v3::Wrapper::P2P'                               => 2,
    'Binary::WebSocketAPI::v3::Wrapper::System'                            => 11,
    'Binary::WebSocketAPI::v3::Wrapper::Transaction'                       => 4,
    'Binary::WebSocketAPI::v3::Wrapper::Accounts'                          => 4,
    'Binary::WebSocketAPI::v3::Wrapper::Streamer'                          => 5,
    'Binary::WebSocketAPI::v3::Wrapper::Pricer'                            => 9,
    'Binary::WebSocketAPI::v3::Wrapper::Cashier'                           => 2,
    'Binary::WebSocketAPI::v3::Wrapper::DocumentUpload'                    => 18,
    'Binary::WebSocketAPI::v3::Wrapper::Authorize'                         => 2,
    'Binary::WebSocketAPI::v3::Wrapper::App'                               => 1,
    'Binary::WebSocketAPI::v3::Subscription::BalanceAll'                   => 8,
    'Binary::WebSocketAPI::v3::Subscription::Transaction'                  => 5,
    'Binary::WebSocketAPI::v3::Subscription::Feed'                         => 2,
    'Binary::WebSocketAPI::v3::Subscription::Pricer'                       => 4,
    'Binary::WebSocketAPI::v3::Subscription::Pricer::Proposal'             => 1,
    'Binary::WebSocketAPI::v3::Subscription::Pricer::ProposalOpenContract' => 1,
    'Binary::WebSocketAPI::v3::Subscription::P2P::Advertiser'              => 7,
    'Binary::WebSocketAPI::v3::Subscription::P2P::Advert'                  => 1,
    'Binary::WebSocketAPI::v3::Subscription::P2P::Order'                   => 9,
};

Test::Pod::CoverageChange::pod_coverage_syntax_ok(allowed_naked_packages => $allowed_naked_packages);

done_testing();
