package BOM::Product::Contract::Turbosshort;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Turbos';

use BOM::Product::Exception;
use Format::Util::Numbers      qw/financialrounding formatnumber/;
use BOM::Product::Utils        qw(rounddown);
use BOM::Product::Role::Turbos qw(SECONDS_IN_A_YEAR);

=head1 DESCRIPTION

The basic idea of Turbos is that the client chooses a barrier level which makes the contract worthless if being crossed by the spot market.
If the barrier wasn't crossed during the whole period of the contract, at maturity, client receives:
Payoff Limited Call = max(SpotT-Barrier, 0) where ST is the  value of the underlying asset at time T

=cut

# finance-contract contract_types.yml to use turbos_call code
# barrier_category add Turbosshort

=head2 _build_ask_probability

Adds markup to theoretical blackscholes option price

=over 4

=item * tick - the tick used to calculate ask probability. This could be different from current tick when take profit is reached.

=back

=cut

sub _build_ask_probability {
    my ($self, $tick) = @_;

    $tick //= $self->current_tick;

    my $prob = Math::Util::CalculatedValue::Validatable->new({
        name        => 'ask_probability',
        description => 'The ask value',
        set_by      => 'BOM::Product::Role::Turbos',
        minimum     => 0,
        base_amount => $self->barrier->as_absolute - $self->theo_ask_probability($tick),
    });

    return $prob;
}

=head2 _build_bid_probability

Adds markup to theoretical blackscholes option price

=cut

sub _build_bid_probability {
    my ($self, $tick, $barrier) = @_;
    $tick    //= $self->entry_tick;
    $barrier //= $self->barrier->as_absolute;

    my $prob = Math::Util::CalculatedValue::Validatable->new({
        name        => 'bid_probability',
        description => 'The bid value',
        set_by      => 'BOM::Product::Role::Turbos',
        minimum     => 0,
        base_amount => $barrier - $self->theo_bid_probability($tick),
    });

    return $prob;
}

=head2 check_expiry_conditions

Checks if contract is expired.

For turbos contract is expired either:
- when expiry time is reached.
- stop out barrier is reached.
- take profit barrier is reached (if applicable)

=cut

sub check_expiry_conditions {
    my $self = shift;

    if ($self->hit_tick) {
        # hit tick could mean one of the two:
        # - hit take profit barrier (close at minimum take profit amount)
        # - hit stop out barrier (close at zero)
        my $value = (defined $self->take_profit and $self->hit_tick->quote < $self->entry_tick->quote) ? $self->calculate_payout($self->hit_tick) : 0;
        $self->value($value);
    } elsif ($self->exit_tick) {
        my $value = ($self->exit_tick->quote < $self->barrier->as_absolute)
            # if contract expires without hitting the barrier, we don't charge spread.
            ? financialrounding('price', $self->currency, $self->number_of_contracts * ($self->barrier->as_absolute - $self->exit_tick->quote))
            : 0;
        $self->value($value);
    }
    return;
}

=head2 calculate_bs_ask_barrier

Calculates the barrier based on the expected spot movement from the current spot, adjusted for volatility. 
This function can compute both the closest and furthest barriers depending on the value passed.

=over 4

=item C<$expected_spot_movement_step>

Specifies the expected spot movement in steps. 

Pass C<$min_expected_spot_movement_step> to calculate the closest barrier relative to the current spot.

Pass C<$max_expected_spot_movement_step> to calculate the furthest barrier relative to the current spot.

=back

=cut

sub calculate_bs_ask_barrier {
    my ($self, $expected_spot_movement_step) = @_;

    my $tick_at_min_start = $self->_tick_at_min_start;
    my $volatility        = $self->pricing_vol;

    my $expected_spot_movement_sqrt   = sqrt($expected_spot_movement_step / SECONDS_IN_A_YEAR);
    my $vol_exp_spot_movement_product = $volatility * $expected_spot_movement_sqrt;
    my $barrier                       = $tick_at_min_start->quote * (1 + $vol_exp_spot_movement_product);
    my $bs_ask_barrier                = $self->_build_bid_probability($tick_at_min_start, $barrier)->amount;

    return $bs_ask_barrier;
}

=head2 calculate_max_stake

Calculate max stake for commission down.

=over 4

=item * volatility - volatility of an underlying symbol. 

=item * min_expected_spot_movement_step - minimum expected spot movement from BO. 

=back

=cut

sub calculate_max_stake {
    my ($self, $min_expected_spot_movement_step) = @_;
    my $volatility                      = $self->pricing_vol;
    my $min_expected_spot_sqrt          = sqrt($min_expected_spot_movement_step / SECONDS_IN_A_YEAR);
    my $volatility_min_exp_spot_product = $volatility * $min_expected_spot_sqrt;
    return ($self->bid_spread + $volatility_min_exp_spot_product);
}

=head2 calculate_barrier
 
calculating the barrier after selecting payout per point

=cut

sub calculate_barrier {
    my $self = shift;

    my $current_spot     = $self->_tick_at_min_start->quote;
    my $commission       = $self->bid_spread;
    my $payout_per_point = $self->number_of_contracts;
    my $stake            = $self->_user_input_stake;
    my $barrier          = rounddown(($stake / $payout_per_point) - ($current_spot * $commission), $self->underlying->pip_size);

    return "+" . $barrier;
}

=head2 calculate_payout

Calculate contract value/payout before expiry. This price includes spread charged.

=over 4

=item * tick - default to current tick.

=back

=cut

sub calculate_payout {
    my ($self, $tick) = @_;

    $tick //= $self->current_tick;

    return financialrounding('price', $self->currency, $self->number_of_contracts * $self->_build_ask_probability($tick)->amount);
}

=head2 _contract_price

calculate contract value

=cut

sub _contract_price {
    my ($self) = @_;

    return $self->_build_bid_probability->amount;
}

=head2 _hit_conditions_barrier

get the barrier details to get the breaching tick

=cut

sub _hit_conditions_barrier {
    my $self = shift;

    return higher => $self->barrier->as_absolute;
}

=head2 take_profit_side

Since the sentiment is down, the take profit barrier will be lower than entry level.

=cut

sub take_profit_side {
    return 'lower';
}

=head2 take_profit_barrier_value($take_profit_amount)

The corresponding barrier/strike value to close the contract with the predefined take profit amount

=over 4

=item C<$take_profit_amount> => numeric

Optional parameter used to calculate new take profit barrier.
Default to $self->take_profit->{amount} if no argument is provided.

=back

=cut

sub take_profit_barrier_value {
    my ($self, $take_profit_amount) = @_;
    $take_profit_amount //= $self->take_profit->{amount};

    if ($take_profit_amount) {
        my $take_profit_barrier =
            ($self->barrier->as_absolute - ($self->ask_price + $take_profit_amount) / $self->number_of_contracts) / (1 + $self->ask_spread);

        return rounddown($take_profit_barrier, $self->underlying->pip_size);
    }

    return undef;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
