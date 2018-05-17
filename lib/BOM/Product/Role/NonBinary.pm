package BOM::Product::Role::NonBinary;

use Moose::Role;

requires 'theo_price', 'base_commission', 'multiplier', 'minimum_bid_price';

use List::Util qw(max min);
use Format::Util::Numbers qw/financialrounding/;

has _ask_price_per_unit => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build__ask_price_per_unit {
    my $self = shift;

    my $ask_price_per_unit = $self->theo_price + $self->commission_per_unit + $self->app_markup_per_unit;
    return max($self->minimum_ask_price_per_unit, $ask_price_per_unit) if $self->can('minimum_ask_price_per_unit');
    return $ask_price_per_unit;
}

override '_build_bid_price' => sub {
    my $self = shift;

    my $bid_price;
    if ($self->is_expired) {
        # if contract can be settled, then return the evaluated contract value
        $bid_price = $self->value;
    } else {
        my $bid_price_per_unit = max($self->minimum_bid_price, $self->_ask_price_per_unit - 2 * $self->commission_per_unit);
        $bid_price = financialrounding('price', $self->currency, $bid_price_per_unit) * $self->multiplier;
    }

    if ($self->can('maximum_bid_price')) {
        $bid_price = min($self->maximum_bid_price, $bid_price);
    }

    return financialrounding('price', $self->currency, $bid_price);
};

override _build_app_markup_dollar_amount => sub {
    my $self = shift;

    financialrounding('price', $self->currency, $self->app_markup_per_unit) * $self->multiplier;
};

override _validate_price => sub {
    my $self = shift;

    my $ERROR_MAPPING = BOM::Product::Static::get_error_mapping();

    my @err;
    if (not $self->ask_price or $self->ask_price == 0) {
        push @err,
            {
            message           => 'Lookbacks ask price can not be zero .',
            message_to_client => [$ERROR_MAPPING->{InvalidNonBinaryPrice}],
            };
    }

    return @err;
};

=head2 commission_per_unit

Return commission of the contract in dollar amount for one unit, not percentage.
A minimum commission of 1 cent is charged for each unit.

=cut

sub commission_per_unit {
    my $self = shift;

    # base_commission is in percentage
    my $base                = $self->base_commission;
    my $commission_per_unit = $self->pricing_engine->theo_price * $base;
    return max($self->minimum_commission_per_unit, $commission_per_unit) if $self->can('minimum_commission_per_unit');
    return $commission_per_unit;
}

sub app_markup_per_unit {
    my $self = shift;

    return $self->pricing_engine->theo_price * $self->app_markup_percentage;
}

1;
