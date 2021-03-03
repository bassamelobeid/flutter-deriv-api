package BOM::Rules::Context;

=head1 NAME

BOM::Rules::Context

=head1 DESCRIPTION

The context of the rule engine that determines a common baseline for all B<rules> and B<actions> being applied and verified.

=cut

use strict;
use warnings;

use Moo;
use LandingCompany::Registry;

=head2 client

A L<BOM::User::Client> object for whom the rules are  being applied.

=cut

has client => (is => 'ro');

=head2 loginid

The B<loginid> of the context's L<client>.

=cut

has loginid => (is => 'ro');

=head2 landing_company

The name of landing company in which the B<actions> takes place. It's usually the same as L<client>'s landing company, but not always.

=cut

has landing_company => (is => 'ro');

=head2 residence

The country of residence. It's usually the same as L<client>'s residence, but not always (for example in virtual account opening).

=cut

has residence => (is => 'ro');

=head2 landing_company_object

The object representing context's L<landing_company>.

=cut

sub landing_company_object {
    my $self = shift;
    $self->{landing_company_object} //= LandingCompany::Registry->new->get($self->landing_company);

    return $self->{landing_company_object};
}

1;
