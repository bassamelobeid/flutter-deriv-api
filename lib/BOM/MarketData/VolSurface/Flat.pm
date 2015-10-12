package BOM::MarketData::VolSurface::Flat;

use Moose;

extends 'BOM::MarketData::VolSurface';

sub _document_content {
    my $self = shift;

    my %structure = (
        flat_vol        => $self->flat_vol,
        flat_atm_spread => $self->flat_atm_spread,
        date            => $self->recorded_date->datetime_iso8601,
        master_cutoff   => $self->cutoff->code,
        symbol          => $self->symbol,
        type            => $self->type,
    );

    return \%structure;
}

with 'BOM::MarketData::Role::VersionedSymbolData';

=head1 NAME

BOM::MarketData::VolSurface::Flat

=head1 DESCRIPTION

Represents a flat volatility surface, with vols at all points being the same

=head1 SYNOPSIS

    my $surface = BOM::MarketData::VolSurface::Delta->new({underlying => BOM::Market::Underlying->new('frxUSDJPY')});

=cut

=head1 ATTRIBUTES

=head2 type

Return the surface type

=cut

has '+type' => (
    default => 'flat',
);

=head2 flat_vol

The flat volatility returned for all points on this surface.

=cut

has flat_vol => (
    is         => 'ro',
    isa        => 'Num',
    lazy_build => 1,
);

sub _build_flat_vol {
    my $self = shift;

    return $self->document->{flat_vol};
}

has flat_atm_spread => (
    is         => 'ro',
    isa        => 'Num',
    lazy_build => 1,
);

has atm_spread_point => (
    is      => 'ro',
    isa     => 'Num',
    default => '50',
);

sub _build_flat_atm_spread {
    my $self = shift;

    return $self->document->{flat_atm_spread};
}

=head2 get_volatility

Given a maturity of some form and a barrier of some form, gives you a vol
from the surface.

USAGE:

  my $vol = $s->get_volatility({delta => 25, days => 7});
  my $vol = $s->get_volatility({strike => $bet->barrier, tenor => '1M'});
  my $vol = $s->get_volatility({delta => 50, expiry_date => Date::Utility->new});

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

sub BUILD {
    my $self             = shift;
    my $atm_spread_point = $self->atm_spread_point;

    $self->{surface} =
        {map { $_ => {vol_spread => {$atm_spread_point => $self->flat_atm_spread}, smile => $self->get_smile($_)} } (qw(1 7 30 90 180 360))};

    return;
}

override is_valid => sub {
    # always true
    return 1;
};

no Moose;
__PACKAGE__->meta->make_immutable;

1;
