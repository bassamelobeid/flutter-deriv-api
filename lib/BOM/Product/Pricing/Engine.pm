package BOM::Product::Pricing::Engine;

=head1 NAME

BOM::Product::Pricing::Engine

=head1 DESCRIPTION

Base class for all pricing engines

=head1 USAGE

Extend this class by:

extends 'BOM::Product::Pricing::Engine';

=cut

use Carp qw(croak);
use Moose;
use Math::Business::BlackScholes::Binaries;
use Math::Util::CalculatedValue::Validatable;

=head1 ATTRIBUTES

=head2 bet

A required parameter to this engine to price.

=cut

has bet => (
    is       => 'ro',
    isa      => 'BOM::Product::Contract',
    weak_ref => 1,
    required => 1,
);

has formula => (
    is         => 'ro',
    isa        => 'CodeRef',
    lazy_build => 1,
);

has _supported_types => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub {
        return {};
    },
);

has [qw(model_markup bs_probability probability d2)] => (
    is         => 'ro',
    isa        => 'Math::Util::CalculatedValue::Validatable',
    lazy_build => 1,
);

# A list of the attributes which can be safely reused when doing a check
# for equal ticks probability.

has _attrs_safe_for_eq_ticks_reuse => (
    is         => 'ro',
    isa        => 'ArrayRef',
    init_arg   => undef,
    lazy_build => 1,
);

sub _build__attrs_safe_for_eq_ticks_reuse {
    # If the subclass does not override this, assume we need to recompute everything.
    return [];
}

sub BUILD {
    my $self = shift;

    my $claimtype = $self->bet->pricing_code;
    croak 'Invalid claimtype[' . $claimtype . '] for engine.' unless $self->_supported_types->{$claimtype};

    return;
}

# For now this is easy, but just in case things get complicated later
sub _build_formula {
    my $self = shift;

    my $formula_name = 'Math::Business::BlackScholes::Binaries::' . lc $self->bet->pricing_code;

    return \&$formula_name;
}

=head2 bs_probability

The unadjusted Black-Scholes probability

=cut

sub _build_bs_probability {
    my $self = shift;

    my $bet  = $self->bet;
    my $args = $bet->pricing_args;

    my @barrier_args = ($bet->two_barriers) ? ($args->{barrier1}, $args->{barrier2}) : ($args->{barrier1});
    my $tv = $self->formula->($args->{spot}, @barrier_args, $args->{t}, $bet->quanto_rate, $bet->mu, $args->{iv}, $args->{payouttime_code});

    my @max = ($bet->payout_type eq 'binary') ? (maximum => 1) : ();
    my $bs_prob = Math::Util::CalculatedValue::Validatable->new({
        name        => 'bs_probability',
        description => 'The Black-Scholes theoretical value',
        set_by      => 'BOM::Product::Pricing::Engine',
        minimum     => 0,
        @max,
        base_amount => $tv,
    });
    return $bs_prob;
}

sub _build_d2 {
    my $self = shift;

    my $bet  = $self->bet;
    my $args = $bet->pricing_args;

    my $d2 = Math::Business::BlackScholes::Binaries::d2($args->{spot}, $args->{barrier1}, $args->{t}, $bet->quanto_rate, $bet->mu, $args->{iv});

    my $d2_ret = Math::Util::CalculatedValue::Validatable->new({
        name        => 'd2',
        description => 'The D2 parameter',
        set_by      => 'BOM::Product::Pricing::Engine',
        base_amount => $d2
    });

    return $d2_ret;
}

=head2 model_markup

The commission from model we should apply for this bet.

=cut

sub _build_model_markup {
    my $self = shift;

    my $model = Math::Util::CalculatedValue::Validatable->new({
        name        => 'model_markup',
        description => 'The markup calculated by this engine.',
        set_by      => 'BOM::Product::Pricing::Engine',
        minimum     => 0,
        maximum     => 100,
        base_amount => 0,
    });
    my $standard = Math::Util::CalculatedValue::Validatable->new({
        name        => 'standard_rate',
        description => 'Our standard markup',
        set_by      => 'BOM::Product::Pricing::Engine',
        base_amount => 0.10,
    });

    $model->include_adjustment('add', $standard);

    return $model;
}

=head2 probability

The probability asccording to this engine for the given bet by default the BS probability;

=cut

sub _build_probability {
    my $self = shift;

    return $self->bs_probability;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
