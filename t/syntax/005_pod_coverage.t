use strict;
use warnings;

use Test::More;
use Test::Pod::CoverageChange;

# This hashref indicates packages which contain sub routines that do not have any POD documentation.
# The number indicates the number of subroutines that are missing POD in the package.
# The number of naked (undocumented) subs should never be increased in this hashref.

my $allowed_naked_packages = {
    'BOM::Product::ContractFinder'                                => 4,
    'BOM::Product::Exception'                                     => 1,
    'BOM::Product::Types'                                         => 0,
    'BOM::Product::Categorizer'                                   => 8,
    'BOM::Product::LimitOrder'                                    => 4,
    'BOM::Product::Pricing::Engine'                               => 7,
    'BOM::Product::Pricing::Greeks'                               => 7,
    'BOM::Product::Role::SingleBarrier'                           => 4,
    'BOM::Product::Role::Callputspread'                           => 8,
    'BOM::Product::Role::NonBinary'                               => 2,
    'BOM::Product::Role::HighLowTicks'                            => 10,
    'BOM::Product::Role::Vanilla'                                 => 0,
    'BOM::Product::Role::Multiplier'                              => 51,
    'BOM::Product::Role::HighLowRuns'                             => 6,
    'BOM::Product::Role::Lookback'                                => 11,
    'BOM::Product::Role::Asian'                                   => 4,
    'BOM::Product::Role::Binary'                                  => 6,
    'BOM::Product::Role::ExpireAtEnd'                             => 0,
    'BOM::Product::Role::AmericanExpiry'                          => 5,
    'BOM::Product::Role::BarrierBuilder'                          => 3,
    'BOM::Product::Role::DoubleBarrier'                           => 5,
    'BOM::Product::Contract::Strike'                              => 12,
    'BOM::Product::Contract::Batch'                               => 3,
    'BOM::Product::ContractFinder::Basic'                         => 3,
    'BOM::Product::Offerings::DisplayHelper'                      => 4,
    'BOM::Product::Offerings::TradingDuration'                    => 1,
    'BOM::Product::Pricing::Greeks::BlackScholes'                 => 0,
    'BOM::Product::Pricing::Greeks::ZeroGreek'                    => 0,
    'BOM::Product::Pricing::Engine::BlackScholes'                 => 0,
    'BOM::Product::Pricing::Engine::VannaVolga'                   => 8,
    'BOM::Product::Contract::Strike::Digit'                       => 1,
    'BOM::Product::Pricing::Engine::Intraday::Forex'              => 19,
    'BOM::Product::Pricing::Engine::Intraday::Index'              => 4,
    'BOM::Product::Pricing::Engine::Role::RiskMarkup'             => 5,
    'BOM::Product::Pricing::Engine::Role::MarketPricedPortfolios' => 9,
    'BOM::Product::Pricing::Engine::VannaVolga::Calibrated'       => 6,
    'BOM::Product::Contract::Digitdiff'                           => 0,
    'BOM::Product::Contract::Ticklow'                             => 4,
    'BOM::Product::ContractVol'                                   => 0,
    'BOM::Product::ContractValidator'                             => 0,
    'BOM::Product::ContractFactory'                               => 3,
    'BOM::Product::Contract::Upordown'                            => 2,
    'BOM::Product::Contract::Digitmatch'                          => 6,
    'BOM::Product::Contract::Resetput'                            => 5,
    'BOM::Product::Contract::Calle'                               => 2,
    'BOM::Product::Contract::Range'                               => 2,
    'BOM::Product::Contract::Callspread'                          => 1,
    'BOM::Product::Contract::Onetouch'                            => 2,
    'BOM::Product::Contract::Resetcall'                           => 5,
    'BOM::Product::Contract::Expiryrange'                         => 2,
    'BOM::Product::Contract::Vanilla_put'                         => 3,
    'BOM::Product::Contract::Expirymisse'                         => 2,
    'BOM::Product::Contract::Digitodd'                            => 6,
    'BOM::Product::Contract::Vanilla_call'                        => 3,
    'BOM::Product::Contract::Expiryrangee'                        => 2,
    'BOM::Product::Contract::Digiteven'                           => 6,
    'BOM::Product::Contract::Put'                                 => 2,
    'BOM::Product::Contract::Multup'                              => 5,
    'BOM::Product::Contract::Expirymiss'                          => 2,
    'BOM::Product::Contract::Invalid'                             => 16,
    'BOM::Product::Contract::Call'                                => 2,
    'BOM::Product::Contract::Lbfloatput'                          => 3,
    'BOM::Product::Contract::Asianu'                              => 1,
    'BOM::Product::Contract::Multdown'                            => 5,
    'BOM::Product::Contract::Notouch'                             => 2,
    'BOM::Product::Contract::Lbhighlow'                           => 4,
    'BOM::Product::Contract::Tickhigh'                            => 4,
    'BOM::Product::Contract::Asiand'                              => 1,
    'BOM::Product::Contract::Digitover'                           => 6,
    'BOM::Product::Contract::Digitunder'                          => 6,
    'BOM::Product::Contract::Runhigh'                             => 2,
    'BOM::Product::Contract::Putspread'                           => 1,
    'BOM::Product::Contract::Pute'                                => 2,
    'BOM::Product::Contract::Digitdiff'                           => 6,
    'BOM::Product::Contract::Runlow'                              => 2,
    'BOM::Product::Contract::Lbfloatcall'                         => 3,
};

my $ignored_packages = ['BOM::Product::Contract', 'BOM::Product::ContractPricer',];

Test::Pod::CoverageChange::pod_coverage_syntax_ok('lib', $allowed_naked_packages, $ignored_packages);

done_testing();
