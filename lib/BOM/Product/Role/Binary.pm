package BOM::Product::Role::Binary;

use Moose::Role;

use BOM::Platform::Config;
use BOM::Product::Static;

use List::Util qw(min max first);
use Scalar::Util qw(looks_like_number);
use Format::Util::Numbers qw(to_monetary_number_format roundnear);

my $ERROR_MAPPING = BOM::Product::Static::get_error_mapping();

sub _build_payout {
    my ($self) = @_;

    $self->_set_price_calculator_params('payout');
    return $self->price_calculator->payout;
}

sub _build_staking_limits {
    my $self = shift;

    my $underlying = $self->underlying;
    my $curr       = $self->currency;

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
            [$ERROR_MAPPING->{StakePayoutLimits}, to_monetary_number_format($stake_min), to_monetary_number_format($payout_max)];
    }

    return {
        min               => $stake_min,
        max               => $payout_max,
        message_to_client => $message_to_client,
    };
}

1;
