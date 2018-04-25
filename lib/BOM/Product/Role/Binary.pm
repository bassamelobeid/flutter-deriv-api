package BOM::Product::Role::Binary;

use Moose::Role;

use BOM::Platform::Config;
use BOM::Product::Static;

use List::Util qw(min);
use Scalar::Util qw(looks_like_number);
use Format::Util::Numbers qw(formatnumber);
use Format::Util::Numbers qw/financialrounding/;

my $ERROR_MAPPING = BOM::Product::Static::get_error_mapping();

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

    $self->_set_price_calculator_params('ask_probability');
    return $self->price_calculator->ask_probability;
}

sub _build_theo_probability {
    my $self = shift;

    $self->_set_price_calculator_params('theo_probability');
    return $self->price_calculator->theo_probability;
}

sub _build_bid_probability {
    my $self = shift;

    $self->_set_price_calculator_params('bid_probability');
    return $self->price_calculator->bid_probability;
}

sub _build_discounted_probability {
    my $self = shift;

    $self->_set_price_calculator_params('discounted_probability');
    return $self->price_calculator->discounted_probability;
}

# the attribute definition is in Finance::Contract
sub _build_payout {
    my ($self) = @_;

    $self->_set_price_calculator_params('payout');
    return $self->price_calculator->payout;
}

override _build_bid_price => sub {
    my $self = shift;

    return $self->_price_from_prob('bid_probability');
};

override _build_ask_price => sub {
    my $self = shift;

    return $self->_price_from_prob('ask_probability');
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

        $self->_set_price_calculator_params($prob);
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

    my $curr = $self->currency;

    my $static     = BOM::Platform::Config::quants;
    my $bet_limits = $static->{bet_limits};
    # NOTE: this evaluates only the contract-specific payout limit. There may be further
    # client-specific restrictions which are evaluated in B:P::Transaction.
    my $per_contract_payout_limit = $static->{risk_profile}{$self->risk_profile->get_risk_profile}{payout}{$self->currency};
    my @possible_payout_maxes = ($bet_limits->{maximum_payout}->{$curr}, $per_contract_payout_limit);
    push @possible_payout_maxes, $bet_limits->{inefficient_period_payout_max}->{$self->currency} if $self->apply_market_inefficient_limit;

    my $payout_max = min(grep { looks_like_number($_) } @possible_payout_maxes);
    my $payout_min =
        ($self->underlying->market->name eq 'volidx')
        ? $bet_limits->{min_payout}->{volidx}->{$curr}
        : $bet_limits->{min_payout}->{default}->{$curr};
    my $stake_min = ($self->for_sale) ? $payout_min / 20 : $payout_min / 2;

    my $message_to_client;
    if ($self->for_sale) {
        $message_to_client = [$ERROR_MAPPING->{MarketPricePayoutClose}];
    } else {
        $message_to_client =
            [$ERROR_MAPPING->{StakePayoutLimits}, formatnumber('price', $curr, $stake_min), formatnumber('price', $curr, $payout_max)];
    }

    return {
        min               => $stake_min,
        max               => $payout_max,
        message_to_client => $message_to_client,
    };
}

1;
