package BOM::Product::Pricing::Greeks;

=head1 NAME

BOM::Product::Pricing::Greeks

=head1 DESCRIPTION

The base Moose class for all Greeks calcuations.

=cut

use Moose;

# Use list of static routines in the same package scope to price greeks:
use Math::Business::BlackScholes::Binaries::Greeks::Delta;
use Math::Business::BlackScholes::Binaries::Greeks::Gamma;
use Math::Business::BlackScholes::Binaries::Greeks::Theta;
use Math::Business::BlackScholes::Binaries::Greeks::Vanna;
use Math::Business::BlackScholes::Binaries::Greeks::Vega;
use Math::Business::BlackScholes::Binaries::Greeks::Volga;

has bet => (
    is       => 'ro',
    isa      => 'BOM::Product::Contract',
    weak_ref => 1,
    required => 1,
);

has _available_greeks => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub {
        return {
            delta => 1,
            gamma => 1,
            theta => 1,
            vega  => 1,
            vanna => 1,
            volga => 1,
        };
    },
);

has [qw(delta gamma theta vega vanna volga)] => (
    is         => 'ro',
    isa        => 'Num',
    lazy_build => 1,
);

sub _build_delta {
    my $self = shift;

    return $self->get_greek('delta');
}

sub _build_gamma {
    my $self = shift;

    return $self->get_greek('gamma');
}

sub _build_theta {
    my $self = shift;

    return $self->get_greek('theta');
}

sub _build_vega {
    my $self = shift;

    return $self->get_greek('vega');
}

sub _build_vanna {
    my $self = shift;

    return $self->get_greek('vanna');
}

sub _build_volga {
    my $self = shift;

    return $self->get_greek('volga');
}

has formulae => (
    is         => 'ro',
    isa        => 'HashRef',
    lazy_build => 1,
);

sub _build_formulae {
    my $self = shift;

    my $formulae = {};
    my $type     = lc $self->bet->pricing_code;

    foreach my $greek (keys %{$self->_available_greeks}) {
        my $formula_name = 'Math::Business::BlackScholes::Binaries::Greeks::' . ucfirst $greek . '::' . $type;
        $formulae->{$greek} = \&$formula_name;
    }

    return $formulae;
}

=head2 get_greeks()


    USAGE
    my (@greeks) = get_greeks($self)

    DESCRIPTION
    Evaluate sub
    Input: none
    Output: (Array) return calculated greeks
    [deltas and gammas are for 1% market move, thetas are for 1 day, vegas are for 1% i.v. move]

=cut

sub get_greeks {
    my $self = shift;

    # PELSSER GAMMA conditions giving problems. And besides
    # we don't really use gamma.
    my $gamma = eval { $self->gamma; } || 0;

    return {
        delta => $self->delta,
        vega  => $self->vega,
        theta => $self->theta,
        gamma => $gamma,
        vanna => $self->vanna,
        volga => $self->volga,
    };
}

=head2 get_greek()

USAGE
my $greek = get_greek($self, $greek, $args)
Input: i)  greek name, e.g. 'delta', 'vega', 'theta', 'vanna', ...
Output: (Array) return calculated greeks

DESCRIPTION
Evaluate sub to get a specific greek

=cut

sub get_greek {
    my ($self, $greek) = @_;
    my $bet  = $self->bet;
    my $args = $bet->_pricing_args;

    return 0 if ($args->{t} <= 0);
    die 'Unknown greek[' . $greek . ']' if not $self->_available_greeks->{$greek};

    my @barrier_args = ($args->{barrier1});
    push @barrier_args, $args->{barrier2} if ($bet->two_barriers);

    my $vol_to_use = ($bet->category_code eq 'vanilla') ? $bet->vol_at_strike : $bet->atm_vols->{fordom};

    return 0.0 if not $self->bet->is_binary;

    return $self->formulae->{$greek}
        ->($args->{spot}, @barrier_args, $args->{t}, $bet->discount_rate, $bet->mu, $vol_to_use, $args->{payouttime_code});
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
