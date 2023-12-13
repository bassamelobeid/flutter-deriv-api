package BOM::Product::Contract::Turboslong;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Turbos';

use BOM::Product::Exception;
use Format::Util::Numbers qw/financialrounding formatnumber/;
use BOM::Product::Utils   qw(roundup);

=head1 DESCRIPTION

The basic idea of Turbos is that the client chooses a barrier level which makes the contract worthless if being crossed by the spot market.
If the barrier wasn't crossed during the whole period of the contract, at maturity, client receives:
Payoff Limited Call = max(SpotT-Barrier, 0) where ST is the  value of the underlying asset at time T

=cut

# finance-contract contract_types.yml to use turbos_call code
# barrier_category add Turboslong

=head2 _build_ask_probability

Adds markup to theoretical blackscholes option price

=cut

sub _build_ask_probability {
    my $self = shift;

    my $prob = Math::Util::CalculatedValue::Validatable->new({
        name        => 'ask_probability',
        description => 'The ask value',
        set_by      => 'BOM::Product::Role::Turbos',
        minimum     => 0,
        base_amount => $self->theo_ask_probability($self->entry_tick) - $self->barrier->as_absolute,
    });

    return $prob;
}

=head2 _build_bid_probability

Adds markup to theoretical blackscholes option price

=over 4

=item * tick - the tick used to calculate bid probability. This could be different from current tick when take profit is reached.

=back

=cut

sub _build_bid_probability {
    my ($self, $tick) = @_;

    my $prob = Math::Util::CalculatedValue::Validatable->new({
        name        => 'bid_probability',
        description => 'The bid value',
        set_by      => 'BOM::Product::Role::Turbos',
        minimum     => 0,
        base_amount => $self->theo_bid_probability($tick) - $self->barrier->as_absolute,
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
        my $value = (defined $self->take_profit and $self->hit_tick->quote > $self->entry_tick->quote) ? $self->calculate_payout($self->hit_tick) : 0;
        $self->value($value);
    } elsif ($self->exit_tick) {
        my $value = ($self->exit_tick->quote > $self->barrier->as_absolute)
            # if contract expires without hitting the barrier, we don't charge spread.
            ? financialrounding('price', $self->currency, $self->number_of_contracts * ($self->exit_tick->quote - $self->barrier->as_absolute))
            : 0;
        $self->value($value);
    }
    return;
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

    return financialrounding('price', $self->currency, $self->number_of_contracts * $self->_build_bid_probability($tick)->amount);
}

=head2 _contract_price

calculate contract value

=cut

sub _contract_price {
    my ($self) = @_;

    return $self->_build_ask_probability->amount;
}

=head2 _hit_conditions_barrier

returns barrier details to get the breaching tick

=cut

sub _hit_conditions_barrier {
    my $self = shift;

    return lower => $self->barrier->as_absolute;
}

=head2 take_profit_side

Since the sentiment is up, the take profit barrier will be higher than entry level.

=cut

sub take_profit_side {
    return 'higher';
}

=head2 take_profit_barrier_value

The corresponding barrier/strike value to close the contract with the predefined take profit amount

=cut

sub take_profit_barrier_value {
    my $self = shift;

    my $value =
        ((($self->ask_price + $self->take_profit->{amount}) / $self->number_of_contracts) + $self->barrier->as_absolute) / (1 - $self->bid_spread);

    return roundup($value, $self->underlying->pip_size);
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
