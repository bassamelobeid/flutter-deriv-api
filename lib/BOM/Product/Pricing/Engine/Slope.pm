package BOM::Product::Pricing::Engine::Slope;

=head1 NAME

BOM::Product::Pricing::Engine::Slope

=head1 DESCRIPTION

A base class.  Instantiating directly is likely to give you now end of headaches.

Price digital options with a vanilla and an adjustment for the vega and vol slope.

=cut

use Moose;
use List::Util qw(min max);
use BOM::Product::ContractFactory qw( make_similar_contract );

extends 'BOM::Product::Pricing::Engine';
with 'BOM::Product::Pricing::Engine::Role::StandardMarkup';
with 'BOM::Product::Pricing::Engine::Role::EuroTwoBarrier';

has _supported_types => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub {
        return {
            CALL        => 1,
            PUT         => 1,
            EXPIRYMISS  => 1,
            EXPIRYRANGE => 1,
        };
    },
);

has [qw(vanilla_vega skew skew_adjustment vanilla_option strike vanilla_price spot)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_probability {
    my $self = shift;

    my $skew_prob = Math::Util::CalculatedValue::Validatable->new({
        name        => 'theoretical_probability',
        description => 'BS pricing adjusted for smile slope.',
        set_by      => 'BOM::Product::Pricing::Engine::Slope',
        minimum     => 0,
        maximum     => 1,
    });

    my $bet = $self->bet;

    my $numeraire_prob = Math::Util::CalculatedValue::Validatable->new({
        name        => 'numeraire_probability',
        description => 'The probability as priced in numeraire currency',
        set_by      => 'BOM::Product::Pricing::Engine::Slope',
        minimum     => 0,
        maximum     => 1,
    });
    if ($bet->two_barriers) {
        # This needs to be broken into two individual contracts.
        # They will be automatically converted per the below
        $skew_prob = $self->euro_two_barrier_probability;
    } elsif ($bet->priced_with eq 'quanto') {
        # Slope pricer doesn't handle quanto as of now. We will price it as a numeraire.
        $numeraire_prob =
            BOM::Product::ContractFactory::make_similar_contract($bet, {currency => $bet->underlying->quoted_currency_symbol})->theo_probability;
        $skew_prob->include_adjustment('reset', $numeraire_prob);
    } elsif ($bet->priced_with eq 'numeraire') {
        $numeraire_prob->include_adjustment('reset', $self->bs_probability);
        $numeraire_prob->include_adjustment('add',   $self->skew_adjustment);
        $skew_prob->include_adjustment('reset', $numeraire_prob);
    } elsif ($bet->priced_with eq 'base') {
        $numeraire_prob =
            BOM::Product::ContractFactory::make_similar_contract($bet, {currency => $bet->underlying->quoted_currency_symbol})->theo_probability;
        $skew_prob->include_adjustment('reset',    $numeraire_prob);
        $skew_prob->include_adjustment('multiply', $self->strike);
        my $which_way = ($bet->sentiment eq 'up') ? 'add' : 'subtract';
        $skew_prob->include_adjustment($which_way, $self->vanilla_price);
        $skew_prob->include_adjustment('divide',   $self->spot);
    }

    return $skew_prob;
}

sub _build_skew_adjustment {
    my $self = shift;

    my $bet = $self->bet;
    my $w = ($bet->is_forward_starting and $bet->underlying->market->name eq 'indices') ? 0 : ($bet->sentiment eq 'up') ? -1 : 1;

    # This is for preventing slope correction in World Indices to go lower than 2%.
    # Since these contracts are similar to coin toss any price far away from 50% on the lower side can have potential for expolit.
    # We will revisit the slope correction again to remove this flooring
    my @min = ($self->bet->underlying->submarket->name eq 'smart_fx') ? (minimum => -0.02) : ();
    my $arg = {
        name        => 'skew_adjustment',
        description => 'The skew adjustment',
        set_by      => 'BOM::Product::Pricing::Engine::Slope',
        base_amount => $w,
        @min,
    };
    # If the first available smile term is more than 3 days away, we cannot accurately calculate the intraday slope. Hence we cap and floor the skew adjustment to 3%.
    if ($bet->volsurface->original_term_for_smile->[0] > 3 and $bet->is_intraday) {
        $arg->{minimum} = -1 * 0.03;
        $arg->{maximum} = 0.03;
    }
    my $skew_adjustment = Math::Util::CalculatedValue::Validatable->new($arg);

    $skew_adjustment->include_adjustment('multiply', $self->vanilla_vega);
    $skew_adjustment->include_adjustment('multiply', $self->skew);

    return $skew_adjustment;
}

sub _build_vanilla_vega {
    my $self = shift;

    my $vanilla_option = $self->vanilla_option;

    my $vega = Math::Util::CalculatedValue::Validatable->new({
        name        => 'vega',
        description => 'Vanilla vega',
        set_by      => 'BOM::Product::Pricing::Engine::Slope',
        base_amount => $vanilla_option->vega,
    });

    return $vega;
}

sub _build_skew {
    my $self = shift;

    my $skew_adjustment = Math::Util::CalculatedValue::Validatable->new({
        name        => 'vol_skew',
        description => 'Just made up',
        set_by      => 'BOM::Product::Pricing::Engine::Slope',
        base_amount => .5,
    });

    return $skew_adjustment;
}

sub _build_strike {
    my $self = shift;

    my $strike = Math::Util::CalculatedValue::Validatable->new({
        name        => 'option_strike',
        description => 'Option strike level',
        set_by      => 'BOM::Product::Contract',
        base_amount => $self->bet->pricing_args->{barrier1},
    });

    return $strike;
}

sub _build_spot {
    my $self = shift;

    my $spot = Math::Util::CalculatedValue::Validatable->new({
        name        => 'option_spot',
        description => 'Option spot level',
        set_by      => 'BOM::Product::Contract',
        base_amount => $self->bet->pricing_args->{spot},
    });

    return $spot;
}

sub _build_vanilla_price {
    my $self = shift;

    return $self->vanilla_option->bs_probability;
}

sub _build_vanilla_option {
    my $self = shift;

    my $bet = $self->bet;

    return BOM::Product::ContractFactory::make_similar_contract(
        $bet,
        {
            bet_type   => 'VANILLA_' . uc $bet->pricing_code,
            volsurface => $bet->volsurface,
        });
}

sub _build_economic_events_markup {
    my $self = shift;

    my $markup = Math::Util::CalculatedValue::Validatable->new({
        name        => 'economic_events_markup',
        description => 'markup for economic events impact',
        set_by      => __PACKAGE__,
        base_amount => $self->economic_events_spot_risk_markup->amount,
    });

    return $markup;
}

around '_build_commission_markup' => sub {
    my $orig = shift;
    my $self = shift;

    if ($self->bet->is_forward_starting and $self->bet->underlying->market->name eq 'indices') {
        return Math::Util::CalculatedValue::Validatable->new({
            name        => 'commission_markup',
            description => 'A fixed 3% markup on forward starting indices',
            set_by      => __PACKAGE__,
            base_amount => 0.03,
        });
    } else {
        return $self->$orig;
    }
};

around '_build_risk_markup' => sub {
    my $orig = shift;
    my $self = shift;

    if ($self->bet->is_forward_starting and $self->bet->underlying->market->name eq 'indices') {
        return Math::Util::CalculatedValue::Validatable->new({
            name        => 'risk_markup',
            description => 'zero risk markup for forward starting indices',
            set_by      => __PACKAGE__,
            base_amount => 0,
        });
    } else {
        return $self->$orig;
    }
};

no Moose;
__PACKAGE__->meta->make_immutable;
1;
