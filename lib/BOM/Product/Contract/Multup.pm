package BOM::Product::Contract::Multup;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Multiplier';

use Math::Business::BlackScholesMerton::NonBinaries;
use Math::Business::BlackScholesMerton::Binaries;

=head1 DESCRIPTION

Multiplier Option is a Contract, for which its current Value and, therefore, Profit or Loss from its purchase changes proportionally to its Base Asset Price change adjusted by Multiplier defined at the moment of contract purchase.

Potential Profit of the Multiplier Option is not limited, while Potential Loss cannot exceed the Stake paid for the Contract by client.

Multiplier Option accepts the following input:

 - Base Asset (E.g. frxEURUSD)
 - Base Asset Price (E.g. 1230.23)
 - Multiplier (E.g. 100)
 - Stake (E.g. 10 USD)

=head2 Profit & Loss

Profit & Loss (PnL) calculation of Multiplier Up Option is as follow:

    $PnL = $stake * ((($current_spot - $basis_spot)/ $basis_spot - $commission) * $multplier);

    where;

    $stake = The amount that user can afford to lose (provided by user)
    $multiplier = The multplier value (provided by user)
    $current_spot = The price of Base Asset at time (n)
    $basis_spot = The price of Base Asset at time when contract was purchased
    $commission = The commission value (E.g. 0.01 = 1%)

Let's imagine that the price of frxEURUSD has moved up by 0.5% from 1000 to 1005. In this case:

    $current_spot = 1005
    $basis_spot = 1000
    $stake = 10
    $multiplier = 100
    $commission = 0

    $PnL = USD 5

=head2 Contract Value

The contract value (CV) at time (n) is calculated with the following following:

    $CV = $stake + $PnL

    where;

    $stake = The amount that user can afford to lose (provided by user)
    $PnL = profit & loss calculated at time (n)

=head2 Stop Out Level

Stop Out level is defined as a percentage from stake at which the contract will be forcefully closed when the contract value touches the level.

For example, a stop out level of 5% means a contract will be forcefully closed when it loses 95% of its stake.

This value is defined in the backoffice and could be changed on demand. Changing of stop out level will not affect historical contracts.

Execution at stop out level is required to guaranteed user to only lose the stake amount when the market is going against them. At the same time,
we are also controlling risk during high volatility period on financial assets.

=head2 Stop Out

Stop Out is the Base Asset price calculated from a function of basis spot and stop out level.

The Stop Out of a Multiplier Up Option is always lower than it basis spot.

Stop Out calculatin is as follow:

    $stop_out = $basis_spot * (1 - ((1 - $stop_out_level) / $multiplier - $commission))

=head2 Take Profit Level

Take Profit level is defined as the minimum amount user wishes to win in their respectively payout currency.

This value is defined by user and it is not required.

=head2 Take Profit

Take Profit is the Base Asset price calculated from a function of basis spot and take profit level.

Take Profit calculation is as follow:

    $take_profit = $basis_spot * (1 + ($take_profit_level / ($stake * $multplier + $commission)));

=head2 Stop Loss Level

Take Profit level is defined as the minimum amount user wishes to lose in their respectively payout currency.

This value is defined by user and it is not required.

=head2 Stop Loss

Stop Loss is the Base Asset price calculated from a function of basis spot and stop loss level.

Stop Loss calculation is as follow:

    $stop_loss = $basis_spot * (1 - ($stop_loss_level / ($stake * $multplier - $commission)));

=head2 Deal Cancellation (cancellation)

Deal cancellation provides a contract cancellation feature for a pre-defined period time at a small fee. Deal cancellation feature can only be purchased
at the beginning of the contract and cannot be updated. If deal cancellation is purchased, one of the 3 scenarios could take place:

    1. The Base Asset price touch Stop Out and the contract is immediately closed with fully refunded stake.
    2. The market is going against your favour and you wish to cancel your contract. You can cancel it manually and have your stake fully refunded.
    3. Deal cancellation expires and contract proceeds as usual.

The pricing model of deal cancellation is a function of take profit and stop out. Hence, the following restrictions are applied:

    1. Deal cancellation cannot be purchased with stop loss.
    2. Deal cancellation can be purchased with take profit. But, take profit cannot be updated until deal cancellation expires.
    3. Deal cancellation cannot be extended.

We have two pricing models for deal cancellation.

Pricing model for deal cancellation with take profit:

    $cost_of_cancellation = $stake * $multipler * (_american_binary_knockout() + _double_knockout());

Pricing model for deal cancellation without take profit:

    $cost_of_cancellation = $stake * $multiplier * _standard_barrier_option();

For detailed explanation of the model, please refer to https://github.com/regentmarkets/quants-docs/blob/master/multiplier/deal_cancellation.ipynb

=cut

sub is_cancelled {
    my $self = shift;

    return 0 unless $self->cancellation;

    # to maintain the cancellation status, if sell_time is present, we will use it.
    my $cmp_date = $self->sell_time ? Date::Utility->new($self->sell_time) : $self->date_pricing;
    my $is_deal_expired = $cmp_date->is_after($self->cancellation_expiry);
    return 1
        if (
        not $is_deal_expired
        and (  ($self->hit_tick and $self->hit_tick->quote <= $self->stop_out->barrier_value)
            or (defined $self->sell_price and $self->sell_price == $self->cancel_price)));
    return 0;
}

sub _standard_barrier_option {
    my $self = shift;

    my $spot           = $self->_spot_proxy;
    my $args           = $self->_formula_args;
    my $exercise_price = $spot + $self->commission;
    my $cash_rebate    = 0;

    return Math::Business::BlackScholesMerton::NonBinaries::standardbarrier($spot, $self->_stop_out_proxy, $exercise_price, $cash_rebate, $args->{t},
        $args->{r}, $args->{q}, $args->{sigma}, $self->_type);
}

sub _american_binary_knockout {
    my $self = shift;

    my $spot                   = $self->_spot_proxy;
    my $args                   = $self->_formula_args;
    my $take_profit_percentage = $self->cancellation_tp / $self->_user_input_stake;
    my $payout                 = $spot * (1 + $take_profit_percentage / $self->multiplier) * exp($self->_barrier_continuity_adjustment) - $spot;

    return Math::Business::BlackScholesMerton::Binaries::americanknockout($spot, $self->_take_profit_proxy, $self->_stop_out_proxy, $payout,
        $args->{t}, $args->{sigma}, $args->{mu}, $self->_type);
}

sub _double_knockout {
    my $self = shift;

    my $spot = $self->_spot_proxy;
    my $args = $self->_formula_args;
    my $K    = $spot * (1 + $self->commission);

    return Math::Business::BlackScholesMerton::NonBinaries::doubleknockout($spot, $self->_take_profit_proxy, $self->_stop_out_proxy, $K, $args->{t},
        $args->{mu}, $args->{sigma}, $args->{r}, $self->_type);
}

has [qw(_take_profit_proxy _stop_out_proxy)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build__take_profit_proxy {
    my $self = shift;

    return 0 unless $self->take_profit;

    my $take_profit_percentage = $self->cancellation_tp / $self->_user_input_stake;

    return $self->_spot_proxy * (1 + $take_profit_percentage / $self->multiplier + $self->commission) * exp($self->_barrier_continuity_adjustment);
}

sub _build__stop_out_proxy {
    my $self = shift;

    return $self->_spot_proxy * (1 - 1 / $self->multiplier + $self->commission) * exp(-1 * $self->_barrier_continuity_adjustment);
}

sub _type {
    return 'c';    # to represent BUY/LONG
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
