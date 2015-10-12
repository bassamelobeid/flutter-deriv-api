package BOM::MarketData::VolSurface::Phased;

use Moose;

extends 'BOM::MarketData::VolSurface';

# I am a horrible person.
## no critic (BuiltinFunctions::ProhibitStringyEval,RequireCheckingReturnValueOfEval)

sub _document_content {
    my $self = shift;

    my %structure = (
        flat_vol            => $self->flat_vol,
        flat_atm_spread     => $self->flat_atm_spread,
        date                => $self->recorded_date->datetime_iso8601,
        master_cutoff       => $self->cutoff->code,
        symbol              => $self->symbol,
        type                => $self->type,
        x_for_epoch_code    => $self->x_for_epoch_code,
        x2_for_epoch_code   => $self->x2_for_epoch_code,
        phase_for_x_code    => $self->phase_for_x_code,
        variance_for_x_code => $self->variance_for_x_code,
    );

    return \%structure;
}

with 'BOM::MarketData::Role::VersionedSymbolData';

=head1 NAME

BOM::MarketData::VolSurface::Phased

=head1 DESCRIPTION

Represents a flat volatility surface with vol varying throughout the day.

These phased surfaces require three addiitonal components:

x_for_epoch_code: a code string which defines how to turn an epoch into a "time of day" in the right space for the following functions.

phase_for_x_code: this takes the 'x' from the above an produces an instantaneous volatility suitable for use in generating a feed.

variance_for_x_code: this represents the area under the curve for a given 'x' value which is used to turn the accumulated variance into a volatility for a contract.

=head1 SYNOPSIS

    my $surface = BOM::MarketData::VolSurface::Phased->new({underlying => BOM::Market::Underlying->new('frxUSDJPY')});

=cut

=head1 ATTRIBUTES

=head2 type

Return the surface type

=cut

has '+type' => (
    default => 'phased',
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

has [qw(x_for_epoch_code x2_for_epoch_code)] => (
    is         => 'ro',
    isa        => 'Str',
    lazy_build => 1,
);

sub _build_x_for_epoch_code {
    my $self = shift;

    return $self->document->{x_for_epoch_code};
}

sub _build_x2_for_epoch_code {
    my $self = shift;

    return $self->document->{x2_for_epoch_code};
}

has [qw(_x_for_epoch_func _x2_for_epoch_func)] => (
    is         => 'ro',
    isa        => 'CodeRef',
    lazy_build => 1,
);

sub _build__x_for_epoch_func {
    my $self = shift;
    return eval($self->x_for_epoch_code);
}

sub _build__x2_for_epoch_func {
    my $self = shift;
    return eval($self->x2_for_epoch_code);
}

has phase_for_x_code => (
    is         => 'ro',
    isa        => 'Str',
    lazy_build => 1,
);

sub _build_phase_for_x_code {
    my $self = shift;

    return $self->document->{phase_for_x_code};
}

has _phase_for_x_func => (
    is         => 'ro',
    isa        => 'CodeRef',
    lazy_build => 1,
);

sub _build__phase_for_x_func {
    my $self = shift;
    return eval($self->phase_for_x_code);
}

has variance_for_x_code => (
    is         => 'ro',
    isa        => 'Str',
    lazy_build => 1,
);

sub _build_variance_for_x_code {
    my $self = shift;

    return $self->document->{variance_for_x_code};
}

has _variance_for_x_func => (
    is         => 'ro',
    isa        => 'CodeRef',
    lazy_build => 1,
);

sub _build__variance_for_x_func {
    my $self = shift;
    return eval($self->variance_for_x_code);
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

    my $for_epoch = $args->{for_epoch} // time;
    my $x = $self->_x_for_epoch_func->($for_epoch);

    return $self->flat_vol * $self->_phase_for_x_func->($x);
}

sub get_smile {
    my $self = shift;

    return {map { $_ => $self->flat_vol } (qw(25 50 75))};
}

=head2 get_volatility_for_period

    $surface->get_volatility_for_period($starting_epoch, $ending_epoch);

The volatility to use for pricing a contract between two epochs.

Computed from the forward-looking variance implied by the path the volatility will take.

=cut

sub get_volatility_for_period {
    my ($self, $start_epoch, $end_epoch) = @_;

    # We ask for 0 time volatility sometimes, for both good and bad reasons.
    # Rather than blowing up, turn it into a 1 second request.
    $start_epoch -= 1 if ($start_epoch == $end_epoch);

    my $crosses_day = Date::Utility->new($end_epoch)->days_between(Date::Utility->new($start_epoch)) > 0 ? 1 : 0;
    my $start_x     = $self->_x_for_epoch_func->($start_epoch);
    my $end_x       = $self->_x2_for_epoch_func->($end_epoch, $crosses_day);

    my $variance_start = $self->_variance_for_x_func->($start_x);
    my $variance_end   = $self->_variance_for_x_func->($end_x);

    return sqrt(($variance_end - $variance_start) / ($end_x - $start_x));
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
