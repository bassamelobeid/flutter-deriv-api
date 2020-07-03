package BOM::Product::Role::NonBinary;

use Moose::Role;

requires 'theo_price', 'base_commission', 'multiplier', 'minimum_bid_price';

use BOM::Config;
use List::Util qw(max min);
use Format::Util::Numbers qw/financialrounding/;
use Scalar::Util qw(looks_like_number);

override '_build_bid_price' => sub {
    my $self = shift;

    my $bid_price;
    if ($self->is_expired) {
        # if contract can be settled, then return the evaluated contract value
        $bid_price = $self->value;
    } else {
        my $ask_price = $self->theo_price + $self->commission;
        my $bid_price_per_unit = max($self->minimum_bid_price, ($ask_price - 2 * $self->commission) / $self->multiplier);
        $bid_price_per_unit = financialrounding('price', $self->currency, $bid_price_per_unit) if $self->user_defined_multiplier;
        $bid_price = $bid_price_per_unit * $self->multiplier;
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

    if (not $self->ask_price or $self->ask_price == 0) {
        return {
            message           => 'Lookbacks ask price can not be zero .',
            message_to_client => [$ERROR_MAPPING->{InvalidNonBinaryPrice}],
            details           => {field => 'amount'},
        };
    }

    my $precision = Format::Util::Numbers::get_precision_config()->{price}->{$self->currency} // 0;
    if (abs($self->ask_price - $self->payout) < 1 / (10**$precision)) {
        return {
            message           => 'buy price is equals to payout',
            message_to_client => [$ERROR_MAPPING->{NoReturn}],
            details           => {},
        };
    }

    my $static     = BOM::Config::quants;
    my $bet_limits = $static->{bet_limits};
    # NOTE: this evaluates only the contract-specific payout limit. There may be further
    # client-specific restrictions which are evaluated in B:P::Transaction.
    my $per_contract_payout_limit = $static->{risk_profile}{$self->risk_profile->get_risk_profile}{payout}{$self->currency};
    my @possible_payout_maxes = ($bet_limits->{maximum_payout}->{$self->currency}, $per_contract_payout_limit);

    my $payout_max = min(grep { looks_like_number($_) } @possible_payout_maxes);

    if ($self->payout > $payout_max) {
        return {
            message           => 'payout exceeded maximum allowed',
            message_to_client => [$ERROR_MAPPING->{PayoutLimitExceeded}, $payout_max],
            details           => {field => 'amount'},
        };
    }

    return;
};

sub commission {
    my $self = shift;

    my $base_commission = $self->base_commission;
    my $base_price      = $self->pricing_engine->base_price;

    my $commission = $base_commission * $base_price;

    my $commission_per_unit =
        $self->can('minimum_commission_per_unit') ? max($self->minimum_commission_per_unit, $base_commission * $base_price) : $commission;

    return $commission_per_unit * $self->multiplier;
}

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

    return $self->pricing_engine->theo_price * $self->app_markup_percentage / 100;
}

override allowed_slippage => sub {
    my $self = shift;

    # Commission is calculated base on ask price for non-binary.
    # We allow price slippage of up to half of our commission charged per contract.
    return financialrounding('price', $self->currency, $self->commission * 0.5);
};

1;
