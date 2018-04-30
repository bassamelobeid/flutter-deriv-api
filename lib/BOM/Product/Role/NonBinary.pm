package BOM::Product::Role::NonBinary;

use Moose::Role;

requires 'theo_price', 'base_commission', 'multiplier', 'minimum_ask_price_per_unit', 'minimum_bid_price';

use List::Util qw(max min);
use Format::Util::Numbers qw/financialrounding/;

=head2 MINIMUM_COMMISSION_PER_UNIT
A minimum of 1 cent commission per unit.
=cut

use constant MINIMUM_COMMISSION_PER_UNIT => 0.01;

override '_build_ask_price' => sub {
    my $self = shift;

    my $ask_price = financialrounding('price', $self->currency, $self->_ask_price_per_unit) * $self->multiplier;
    if ($self->can('maximum_ask_price')) {
        $ask_price = financialrounding('price', $self->currency, min($self->maximum_ask_price, $ask_price));
    }

    return $ask_price;
};

has _ask_price_per_unit => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build__ask_price_per_unit {
    my $self = shift;

    return max($self->minimum_ask_price_per_unit, $self->theo_price + $self->commission_per_unit + $self->app_markup_per_unit);
}

override '_build_bid_price' => sub {
    my $self = shift;

    my $bid_price;
    if ($self->is_expired) {
        # if contract can be settled, then return the evaluated contract value
        $bid_price = financialrounding('price', $self->currency, $self->value);
    } else {
        my $bid_price_per_unit = max($self->minimum_bid_price, $self->_ask_price_per_unit - 2 * $self->commission_per_unit);
        $bid_price = financialrounding('price', $self->currency, $bid_price_per_unit) * $self->multiplier;
    }

    if ($self->can('maximum_bid_price')) {
        $bid_price = financialrounding('price', $self->currency, min($self->maximum_bid_price, $bid_price));
    }

    return $bid_price;
};

override _build_app_markup_dollar_amount => sub {
    my $self = shift;

    financialrounding('price', $self->currency, $self->app_markup_per_unit) * $self->multiplier;
};

=head2 commission_per_unit

Return commission of the contract in dollar amount for one unit, not percentage.
A minimum commission of 1 cent is charged for each unit.

=cut

sub commission_per_unit {
    my $self = shift;

    # base_commission is in percentage
    my $base = $self->base_commission;

    return max(MINIMUM_COMMISSION_PER_UNIT, $self->pricing_engine->theo_price * $base);
}

sub app_markup_per_unit {
    my $self = shift;

    return $self->pricing_engine->theo_price * $self->app_markup_percentage;
}

1;
