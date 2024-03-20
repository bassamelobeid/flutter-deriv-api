use Object::Pad;

class BOM::Config::TradingPlatform::Jurisdiction;

use strict;
use warnings;

=head1 NAME

C<BOM::Config::TradingPlatform::Jurisdiction>

=head1 DESCRIPTION

A class helper functions to return trading platform jurisdiction config.

This only includes jurisdiction that requires proof of identity and proof of address verification.

It does not exports these functions by default.

=cut

use Object::Pad;
use Syntax::Keyword::Try;
use List::Util qw(any);

use BOM::Config::Runtime;
use BOM::Config;

=head2 jurisdiction_config

Contain the config of cfds_jurisdiction.yml

=cut

field $jurisdiction_config : reader;

=head2 jurisdictions

Hash reference of jurisdictions and its config.

=cut

field $jurisdictions : reader = {};

=head2 new

Builder method to create new instance of this class.

=cut

BUILD {
    $jurisdiction_config = BOM::Config::cfds_jurisdiction_config();

    die "Cannot load cfds_jurisdiction config." unless $jurisdiction_config;

    foreach my $jurisdiction (keys %{$jurisdiction_config->{jurisdictions}}) {
        $jurisdictions->{$jurisdiction} = $jurisdiction_config->{jurisdictions}->{$jurisdiction};
    }
}

=head2 get_verification_required_jurisdiction_list

Return the list of jurisdiction that requires proof of identity and proof of address verification.

=cut

method get_verification_required_jurisdiction_list {
    return keys %$jurisdictions;
}

=head2 get_jurisdiction_list_with_grace_period

Return the list of jurisdiction that have grace period.

=cut

method get_jurisdiction_list_with_grace_period {
    return grep { $self->is_jurisdiction_grace_period_enforced($_) } keys %$jurisdictions;
}

=head2 is_jurisdiction_grace_period_enforced

Return the boolean value if given jurisdiction is grace period enforced.

=over

=item * C<jurisdiction> jurisdiction short name, example: bvi

=back

Boolean integer value.

=cut

method is_jurisdiction_grace_period_enforced {
    my $jurisdiction = shift;
    my $enforced     = $jurisdictions->{$jurisdiction}->{grace_period}->{enforced} ? 1 : 0;

    return $enforced;
}

=head2 get_jurisdiction_grace_period

Return the grace period value in days given jurisdiction.

=over

=item * C<jurisdiction> jurisdiction short name, example: bvi

=back

Grace period integer value in days.

=cut

method get_jurisdiction_grace_period {
    my $jurisdiction = shift;
    my $grace_period = $jurisdictions->{$jurisdiction}->{grace_period}->{days};

    die "Cannot find grace period for $jurisdiction" unless defined $grace_period;

    return $grace_period;
}

=head2 get_jurisdiction_proof_requirement

Return the list of proof requirements of poi, poa given jursidiction.

=over

=item * C<jurisdiction> jurisdiction short name, example: bvi

=back

Proof requirements in array. Example: ('poi', 'poa')

=cut

method get_jurisdiction_proof_requirement {
    my $jurisdiction       = shift;
    my $proof_requirements = $jurisdictions->{$jurisdiction}->{proof_requirements} // [];

    return @$proof_requirements;
}

1;
