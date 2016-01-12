package BOM::MarketData::VolSurface::Flat;

use feature 'state';

use Moose;
use YAML::XS qw(LoadFile);
extends 'BOM::MarketData::VolSurface';

=head1 NAME

BOM::MarketData::VolSurface::Flat

=head1 DESCRIPTION

Represents a flat volatility surface, with vols at all points being the same

=head1 SYNOPSIS

    my $surface = BOM::MarketData::VolSurface::Flat->new({underlying => BOM::Market::Underlying->new('frxUSDJPY')});
    my $vol     = $surface->get_volatility();

=cut

=head1 ATTRIBUTES

=head2 type

Return the surface type

=cut

state $vol = LoadFile('/home/git/regentmarkets/bom-market/config/files/flat_volatility.yml');

has '+type' => (
    default => 'flat',
);

has atm_spread_point => (
    is      => 'ro',
    default => '50',
);

=head2 flat_vol

The flat volatility returned for all points on this surface.

=cut

has flat_vol => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_flat_vol {
    my $self = shift;
    return $vol->{$self->underlying->symbol};
}

# a fixed 7% of volatility spread
has flat_atm_spread => (
    is      => 'ro',
    default => 0.07,
);

=head2 get_volatility

Returns a flat volatility.

USAGE:

  my $flat_vol = $s->get_volatility();

=cut

sub get_volatility {
    my ($self, $args) = @_;

    # There is no sanity checking on the args, because you
    # get the same answer, not matter what you ask.
    return $self->flat_vol;
}

sub get_smile {
    my $self = shift;

    return {map { $_ => $self->flat_vol } (qw(25 50 75))};
}

sub get_market_rr_bf {
    my ($self, $day) = @_;

    my %deltas = %{$self->get_smile($day)};

    return $self->SUPER::get_rr_bf_for_smile(\%deltas);
}

# just a flat surface for consistency.
has surface => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_surface',
);

sub _build_surface {
    my $self = shift;

    return {map { $_ => {vol_spread => {$self->atm_spread_point => $self->flat_atm_spread}, smile => $self->get_smile($_)} } (qw(1 7 30 90 180 360))};
}

has recorded_date => (
    is      => 'ro',
    default => sub { Date::Utility->new },
);

override is_valid => sub {
    # always true
    return 1;
};

no Moose;
__PACKAGE__->meta->make_immutable;

1;
