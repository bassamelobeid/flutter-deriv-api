package BOM::Market::Asset;

=head1 NAME

BOM::Market::Asset

=head1 DESCRIPTION

Assets have a symbol and rates. Example assets are currencies, indices, stocks
and commodities.

=cut

use Moose;
use BOM::MarketData::Dividend;
use Date::Utility;

=head2 symbol

Represents symbol of the asset.

=cut

has symbol => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

has for_date => (
    is      => 'ro',
    isa     => 'Maybe[Date::Utility]',
    default => undef,
);

sub rate_for {
    my ($self, $tiy) = @_;

    return BOM::MarketData::Dividend->new(symbol => $self->symbol)->rate_for($tiy);
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
