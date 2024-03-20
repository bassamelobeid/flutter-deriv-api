package BOM::Contract;

use v5.26;
use warnings;

use Moose;

has inner_contract => (
    is       => 'ro',
    required => 1,
);

=head2 metadata

Returns contract metadata as a hashref. Includes contract category and type,
symbol and market, barrier category, expiry type, start type, duration

=cut

sub metadata {
    my ($self, @args) = @_;
    return $self->inner_contract->metadata(@args);
}

no Moose;

__PACKAGE__->meta->make_immutable;

1;
