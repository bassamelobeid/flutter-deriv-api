use strict;
use warnings;

use Test::More;
use Test::Pod::CoverageChange;

# This hashref indicates packages which contain sub routines that do not have any POD documentation.
# The number indicates the number of subroutines that are missing POD in the package.
# The number of naked (undocumented) subs should never be increased in this hashref.

my $allowed_naked_packages = {
    'BOM::User'                                        => 30,
    'BOM::User::Client'                                => 74,
    'BOM::User::AuditLog'                              => 1,
    'BOM::User::Utility'                               => 5,
    'BOM::User::Password'                              => 3,
    'BOM::User::FinancialAssessment'                   => 4,
    'BOM::User::Client::Status'                        => 40,
    'BOM::User::Client::Account'                       => 4,
    'BOM::User::Client::PaymentTransaction'            => 19,
    'BOM::User::Client::Payments'                      => 0,
    'BOM::User::Client::PaymentNotificationQueue'      => 2,
    'BOM::User::Client::PaymentAgent'                  => 5,
    'BOM::User::Script::AMLClientsUpdate'              => 1,
    'BOM::User::Script::MirrorBinaryUserId'            => 2,
    'BOM::MT5::User::Async'                            => 13,
    'BOM::User::Client::PaymentTransaction::Doughflow' => 2,

};

Test::Pod::CoverageChange::pod_coverage_syntax_ok('lib', $allowed_naked_packages);

done_testing();
