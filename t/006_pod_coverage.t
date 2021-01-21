use strict;
use warnings;

use Test::More;
use Test::Pod::CoverageChange;

# This hashref indicates packages which contain sub routines that do not have any POD documentation.
# The number indicates the number of subroutines that are missing POD in the package.
# The number of naked (undocumented) subs should never be increased in this hashref.

my $allowed_naked_packages = {
    'BOM::User'                                        => 30,
    'BOM::User::Client'                                => 70,
    'BOM::User::AuditLog'                              => 1,
    'BOM::User::Utility'                               => 5,
    'BOM::User::Password'                              => 3,
    'BOM::User::FinancialAssessment'                   => 4,
    'BOM::User::Client::Status'                        => 45,
    'BOM::User::Client::Account'                       => 4,
    'BOM::User::Client::PaymentTransaction'            => 19,
    'BOM::User::Client::PaymentNotificationQueue'      => 2,
    'BOM::User::Client::PaymentAgent'                  => 5,
    'BOM::User::Script::AMLClientsUpdate'              => 2,
    'BOM::User::Script::MirrorBinaryUserId'            => 2,
    'BOM::MT5::User::Async'                            => 12,
    'BOM::User::Client::PaymentTransaction::Doughflow' => 2,

};

=head2 reasons

=over 4

=item BOM::User::Client::Payments

We ignore L<BOM::User::Client::Payments> because it fails on load. You can check the package's content.

=back

=cut

Test::Pod::CoverageChange::pod_coverage_syntax_ok(
    allowed_naked_packages => $allowed_naked_packages,
    ignored_packages       => ['BOM::User::Client::Payments']);

done_testing();
