package BOM::MarketData::VolSurface::Phased;

use Moose;
extends 'BOM::MarketData::VolSurface';

use List::Util qw(first);
use Carp qw(croak);

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

sub BUILD {
    my $self = shift;

    my %supported_symbols = map { $_ => 1 } qw(RDMARS RDVENUS RDMOON RDSUN);
    unless ($supported_symbols{$self->underlying->symbol}) {
        croak "Invalid usage of phased volatility for underlying [" . $self->underlying->symbol . "]";
    }

    return;
}

sub _phase_for_x {
    my ($self, $x) = @_;

    my $symbol = $self->underlying->symbol;
    my $curve;
    if ($symbol eq 'RDMARS') {
        $curve = cos($x);
    } elsif ($symbol eq 'RDVENUS') {
        $curve = -cos($x);
    } elsif ($symbol eq 'RDMOON') {
        $curve = -sin($x);
    } elsif ($symbol eq 'RDSUN') {
        $curve = sin($x);
    }

    return (1.5 + $curve);
}

sub _variance_for_x {
    my ($self, $x) = @_;

    my $symbol = $self->underlying->symbol;

    if ($symbol eq 'RDMARS') {
        return (2.75 * $x + 3 * sin($x) + 0.25 * sin(2 * $x));
    } elsif ($symbol eq 'RDVENUS') {
        return (2.75 * $x - 3 * sin($x) + 0.25 * sin(2 * $x));
    } elsif ($symbol eq 'RDMOON') {
        return (2.75 * $x + 3 * cos($x) - 0.25 * sin(2 * $x));
    } elsif ($symbol eq 'RDSUN') {
        return (2.75 * $x - 3 * cos($x) - 0.25 * sin(2 * $x));
    }

    return;
}

sub _x_for_epoch {
    my ($self, $epoch) = @_;
    my $secs_after = $epoch % 86400;
    return 3.1415926 * $secs_after / 43200;
}

sub _x2_for_epoch {
    my ($self, $epoch, $crosses_day) = @_;
    my $secs_after = ($crosses_day) ? ($epoch % 86400) + 86400 : $epoch % 86400;
    return 3.1415926 * $secs_after / 43200;
}

has flat_atm_spread => (
    is      => 'ro',
    default => 0,
);

has atm_spread_point => (
    is      => 'ro',
    default => '50',
);

=head2 get_volatility

The volatility to use for pricing a contract between two epochs.
Computed from the forward-looking variance implied by the path the volatility will take.

    $surface->get_volatility({start_epoch => $starting_epoch, end_epoch => $ending_epoch});

=cut

sub get_volatility {
    my ($self, $args) = @_;

    my ($start_epoch, $end_epoch) = @{$args}{'start_epoch', 'end_epoch'};
    my $for_epoch = $args->{for_epoch};

    # get_volatility for a single point in time
    return $self->_phase_for_x_func->($self->_x_for_epoch_func->($for_epoch)) if ($for_epoch);

    unless ($start_epoch and $end_epoch) {
        croak "Invalid usage of phased volatility. start_epoch and end_epoch are required.";
    }
    # We ask for 0 time volatility sometimes, for both good and bad reasons.
    # Rather than blowing up, turn it into a 1 second request.
    $start_epoch -= 1 if ($start_epoch == $end_epoch);

    my $crosses_day = Date::Utility->new($end_epoch)->days_between(Date::Utility->new($start_epoch)) > 0 ? 1 : 0;
    my $start_x     = $self->_x_for_epoch($start_epoch);
    my $end_x       = $self->_x2_for_epoch($end_epoch, $crosses_day);

    my $variance_start = $self->_variance_for_x($start_x);
    my $variance_end   = $self->_variance_for_x($end_x);

    return sqrt(($variance_end - $variance_start) / ($end_x - $start_x));
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

sub get_smile {
    my $self = shift;

    return {map { $_ => 1 } (qw(25 50 75))};
}

override is_valid => sub {
    # always true
    return 1;
};

no Moose;
__PACKAGE__->meta->make_immutable;
1;
