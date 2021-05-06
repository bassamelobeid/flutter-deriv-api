use strict;
use warnings;

use Test::More;
use Test::Pod::CoverageChange;

# This hashref indicates packages which contain sub routines that do not have any POD documentation.
# The number indicates the number of subroutines that are missing POD in the package.
# The number of naked (undocumented) subs should never be increased in this hashref.

my $allowed_naked_packages = {
    'BOM::Platform::RiskProfile'                 => 18,
    'BOM::Platform::Locale'                      => 1,
    'BOM::Platform::Token'                       => 2,
    'BOM::Platform::ProveID'                     => 4,
    'BOM::Platform::Copier'                      => 4,
    'BOM::Platform::S3Client'                    => 7,
    'BOM::Platform::Context'                     => 2,
    'BOM::Platform::Account::Virtual'            => 1,
    'BOM::Platform::Client::IDAuthentication'    => 2,
    'BOM::Platform::Client::DoughFlowClient'     => 16,
    'BOM::Platform::Context::Request'            => 11,
    'BOM::Platform::Context::I18N'               => 1,
    'BOM::Platform::Sendbird::Webhook'           => 1,
    'BOM::Platform::Token::API'                  => 10,
    'BOM::Platform::Script::MonthlyClientReport' => 2,
    'BOM::Platform::Script::TradeWarnings'       => 6,
    'BOM::Platform::Script::NotifyPub'           => 6,
    'BOM::Platform::Event::Emitter'              => 3,
    'BOM::Platform::Account::Real::default'      => 3,
    'BOM::Platform::Account::Real::maltainvest'  => 1,
    'BOM::Platform::Context::Request::Builders'  => 1,
};

Test::Pod::CoverageChange::pod_coverage_syntax_ok(allowed_naked_packages => $allowed_naked_packages);

done_testing();
