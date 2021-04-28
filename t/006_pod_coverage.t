use strict;
use warnings;

use Test::More;
use Test::Pod::CoverageChange;
use FindBin;
use lib "$FindBin::Bin/..";    # include root files.

# This hashref indicates packages which contain sub routines that do not have any POD documentation.
# The number indicates the number of subroutines that are missing POD in the package.
# The number of naked (undocumented) subs should never be increased in this hashref.

my $allowed_naked_packages = {
    'BOM::ContractInfo'                                  => 1,
    'BOM::PricingDetails'                                => 16,
    'BOM::DailySummaryReport'                            => 6,
    'BOM::DynamicSettings'                               => 9,
    'BOM::DualControl'                                   => 23,
    'BOM::JavascriptConfig'                              => 1,
    'BOM::StaffPages'                                    => 1,
    'BOM::RiskReporting::ScenarioAnalysis'               => 3,
    'BOM::RiskReporting::Base'                           => 11,
    'BOM::RiskReporting::MarkedToModel'                  => 7,
    'BOM::RiskReporting::Dashboard'                      => 17,
    'BOM::Backoffice::Auth0'                             => 6,
    'BOM::Backoffice::QuantsAuditLog'                    => 1,
    'BOM::Backoffice::Form'                              => 5,
    'BOM::Backoffice::CustomCommissionTool'              => 7,
    'BOM::Backoffice::FormAccounts'                      => 3,
    'BOM::Backoffice::Request'                           => 6,
    'BOM::Backoffice::Config'                            => 2,
    'BOM::Backoffice::PricePreview'                      => 3,
    'BOM::Backoffice::Cookie'                            => 5,
    'BOM::Backoffice::ExperianBalance'                   => 2,
    'BOM::Backoffice::EconomicEventPricePreview'         => 5,
    'BOM::Backoffice::QuantsConfigHelper'                => 13,
    'BOM::Backoffice::PlackApp'                          => 1,
    'BOM::Backoffice::Utility'                           => 3,
    'BOM::Backoffice::PlackHelpers'                      => 7,
    'BOM::Backoffice::EconomicEventTool'                 => 11,
    'BOM::Backoffice::Sysinit'                           => 5,
    'BOM::Backoffice::Script::SetLimitForQuietPeriod'    => 3,
    'BOM::Backoffice::Script::ValidateStaffPaymentLimit' => 1,
    'BOM::Backoffice::Script::ExtraTranslations'         => 15,
    'BOM::Backoffice::Script::CopyTradingStatistics'     => 1,
    'BOM::Backoffice::Script::Riskd'                     => 4,
    'BOM::Backoffice::Script::RiskScenarioAnalysis'      => 1,
    'BOM::Backoffice::Script::UpdateTradingStrategyData' => 1,
    'BOM::Backoffice::Request::Base'                     => 11,
    'BOM::Backoffice::Request::Role'                     => 4,
    'BOM::MarketData::Display::VolatilitySurface'        => 8,
    'BOM::Backoffice::CGI::SettingWebsiteStatus'         => 54
};

Test::Pod::CoverageChange::pod_coverage_syntax_ok(allowed_naked_packages => $allowed_naked_packages);

done_testing();
