package BOM::Product::Offerings::DisplayHelper::Options;

use Moose;
use namespace::autoclean;
extends 'BOM::Product::Offerings::DisplayHelper';

=head2 get_submarkets

Returns an array of submarkets that is offered on in-house platform.

=cut

sub get_submarkets {
    my ($self, $market) = @_;

    return $self->offerings->query({market => $market->name}, ['submarket']);
}

=head2 get_symbols_for_submarket

Get symbols for a given submarket and market that are offered on in-house platform.

=cut

sub get_symbols_for_submarket {
    my ($self, $market, $submarket) = @_;

    return $self->offerings->query({
            market    => $market->name,
            submarket => $submarket->name
        },
        ['underlying_symbol']);

}

__PACKAGE__->meta->make_immutable;

1;
