package BOM::Product::Role::Binary;

use Moose::Role;

use BOM::Config;
use BOM::Product::Static;
use BOM::Config::ContractPricingLimits qw/market_pricing_limits/;

use List::Util qw(min);
use Scalar::Util qw(looks_like_number);
use Format::Util::Numbers qw(formatnumber);
use Format::Util::Numbers qw/financialrounding/;
use Try::Tiny;

my $ERROR_MAPPING = BOM::Product::Static::get_error_mapping();

# discounted_probability - The discounted total probability, given the time value of the money at stake.
has [qw(
        ask_probability
        theo_probability
        bid_probability
        discounted_probability
        )
    ] => (
    is         => 'ro',
    isa        => 'Math::Util::CalculatedValue::Validatable',
    lazy_build => 1,
    );

sub _build_ask_probability {
    my $self = shift;

    # ask_probability needs computed theo_probability
    $self->price_calculator->theo_probability($self->theo_probability);
    return $self->price_calculator->ask_probability;
}

sub _build_theo_probability {
    my $self = shift;

    # compute theo_probability based on engine and set it as a Price::Calculator parameter
    my $probability =
        $self->new_interface_engine
        ? Math::Util::CalculatedValue::Validatable->new({
            name        => 'theo_probability',
            description => 'theoretical value of a contract',
            set_by      => $self->pricing_engine_name,
            base_amount => $self->pricing_engine->theo_probability,
            minimum     => 0,
            maximum     => 1,
        })
        : $self->pricing_engine->probability;
    return $self->price_calculator->theo_probability($probability);
}

sub _build_bid_probability {
    my $self = shift;

    # bid_probability needs theo_probability, discounted_probability, and opposite_ask_probability
    $self->price_calculator->theo_probability($self->theo_probability);
    $self->price_calculator->discounted_probability($self->discounted_probability);
    $self->price_calculator->opposite_ask_probability($self->opposite_contract_for_sale->ask_probability);
    return $self->price_calculator->bid_probability;
}

sub _build_discounted_probability {
    my $self = shift;

    # discounted_probability needs timeinyears and discount_rate
    $self->price_calculator->timeinyears($self->timeinyears);
    $self->price_calculator->discount_rate($self->discount_rate);
    return $self->price_calculator->discounted_probability;
}

# the attribute definition is in Finance::Contract
sub _build_payout {
    my ($self) = @_;

    my $payout;
    try {
        # payout needs theo_probability and commission_from_stake
        $self->price_calculator->theo_probability($self->theo_probability);
        $self->price_calculator->commission_from_stake($self->commission_from_stake);
        #return $self->price_calculator->payout;
        $payout = $self->price_calculator->payout;
    }
    catch {
        if (
            $_ =~ /Illegal division by zero/
            and (
                (defined $self->supplied_barrier and looks_like_number($self->supplied_barrier) and $self->supplied_barrier == 0)
                or (    defined $self->supplied_high_barrier
                    and defined $self->supplied_low_barrier
                    and looks_like_number($self->supplied_high_barrier)
                    and looks_like_number($self->supplied_low_barrier)
                    and ($self->supplied_high_barrier == 0 or $self->supplied_low_barrier == 0))))
        {
            $payout = 0;
        }

    };

    return $payout;
}

override _build_bid_price => sub {
    my $self = shift;

    # - Ensure bid_probability and other probabilities exist before computing bid_price
    #   For some reason, $self->bid_probability is not enough to trigger lazy build
    # - We do not calculate price for expired contracts.
    # - $self->is_expired could be false at the expiry or 1 second after the expiry time
    #   because we're waiting for exit_tick, so we should avoid calculating bid price for this condition either.
    $self->_build_bid_probability if $self->date_pricing->is_before($self->date_expiry) and not $self->is_expired;

    return $self->_price_from_prob('bid_probability');
};

override _build_ask_price => sub {
    my $self = shift;

    # Ensure theo_probability exists before computing ask_probability/ask_price
    $self->theo_probability;

    my $ask_price = $self->_price_from_prob('ask_probability');

    # publish ask price to pricing server
    $self->_publish({ask_price => $ask_price});

    return $ask_price;
};

override _build_theo_price => sub {
    my $self = shift;

    return $self->_price_from_prob('theo_probability');
};

override _build_app_markup_dollar_amount => sub {
    my $self = shift;

    return financialrounding('amount', $self->currency, $self->app_markup->amount * $self->payout);
};

sub _price_from_prob {
    my ($self, $prob) = @_;
    if ($self->date_pricing->is_after($self->date_start) and $self->is_expired) {
        $self->price_calculator->value($self->value);
    } else {

        # Call the corresponding builder methods above for a given prob to set Price::Calculator params
        $self->$prob;
    }
    return $self->price_calculator->price_from_prob($prob);
}

has 'staking_limits' => (
    is         => 'ro',
    isa        => 'HashRef',
    lazy_build => 1,
);

sub _build_staking_limits {
    my $self = shift;
    # NOTE: this evaluates only the contract-specific payout limit. There may be further
    # client-specific restrictions which are evaluated in B:P::Transaction =>
    my $curr   = $self->currency;
    my $lc     = $self->landing_company;
    my $market = $self->underlying->market->name;

    my $bet_limits = market_pricing_limits([$curr], $lc, [$market])->{$market}->{$curr};
    my $static = BOM::Config::quants;

    my $bl_min = $bet_limits->{min_stake};
    my $bl_max = $bet_limits->{max_payout};

    my $per_contract_payout_limit = $static->{risk_profile}{$self->risk_profile->get_risk_profile}{payout}{$self->currency};
    my @possible_payout_maxes = ($bl_max, $per_contract_payout_limit);
    push @possible_payout_maxes, $static->{bet_limits}->{inefficient_period_payout_max}->{$self->currency} if $self->apply_market_inefficient_limit;
    push @possible_payout_maxes, $static->{bet_limits}->{restricted_payout_contract_categories}->{$self->category_code}->{$self->currency}
        if $static->{bet_limits}->{restricted_payout_contract_categories}->{$self->category_code};

    my $payout_max = min(grep { looks_like_number($_) } @possible_payout_maxes);

    my $stake_min = ($self->for_sale) ? $bl_min / 10 : $bl_min;

    return {
        min => $stake_min,
        max => $payout_max,
    };
}

1;
