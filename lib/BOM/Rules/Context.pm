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

=head2 stop_on_failure

Prevents exit on the first failure and perform all actions

=cut

has stop_on_failure => (
    is      => 'ro',
    default => 1
);

=head2 landing_company_object

The object representing context's L<landing_company>.

=cut

sub landing_company_object {
    my $self = shift;
    $self->{landing_company_object} //= LandingCompany::Registry->new->get($self->landing_company);

    return $self->{landing_company_object};
}

=head2 client_switched

If the context client is virtual has a real sibling account in the context landing company, it will return that real sibling;
otherwise it will return the context client itself.

=cut

sub client_switched {
    my $self = shift;

    my $client = $self->client;

    return $client unless ($client and $client->user and not $client->is_virtual);

    $self->{client_switch} //=
        (sort { $b->date_joined cmp $a->date_joined } grep { not $_->is_virtual } $client->user->clients(include_disabled => 0))[0] // $client;

    return $self->{client_switch};
}

=head2 client_type

Returns the client type as a string with three values: virtual,real, none (no context client)

=cut

sub client_type {
    my $self = shift;

    return 'none' unless $self->client;

    return $self->client->is_virtual ? 'virtual' : 'real';
}

1;
