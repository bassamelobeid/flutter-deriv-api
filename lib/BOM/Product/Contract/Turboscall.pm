package BOM::Product::Contract::Turboscall;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::ExpireAtEnd', 'BOM::Product::Role::Turbos';

use BOM::Product::Exception;
use Format::Util::Numbers qw/financialrounding formatnumber/;

=head1 DESCRIPTION

The basic idea of Turbos is that the client chooses a barrier level which makes the contract worthless if being crossed by the spot market.
If the barrier wasn't crossed during the whole period of the contract, at maturity, client receives:
Payoff Limited Call = max(SpotT-Barrier, 0) where ST is the  value of the underlying asset at time T

=cut

# finance-contract contract_types.yml to use turbos_call code
# barrier_category add Turboscall

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
        base_amount => $self->theo_ask_probability - $self->barrier->as_absolute,
    });

    return $prob;
}

=head2 _build_bid_probability

Adds markup to theoretical blackscholes option price

=cut

sub _build_bid_probability {
    my $self = shift;

    my $prob = Math::Util::CalculatedValue::Validatable->new({
        name        => 'bid_probability',
        description => 'The bid value',
        set_by      => 'BOM::Product::Role::Turbos',
        minimum     => 0,
        base_amount => $self->theo_bid_probability - $self->barrier->as_absolute,
    });

    return $prob;
}

=head2 check_expiry_conditions

Checks if contract is expired.
For turbos contract is expired only when expiry time is reached.
Contract will have value if price didn't cross the barrier

=cut

sub check_expiry_conditions {
    my $self = shift;

    if ($self->hit_tick) {
        $self->value(0);
    } elsif ($self->exit_tick) {
        my $value =
            ($self->exit_tick->quote > $self->barrier->as_absolute)
            ? $self->calculate_payout
            : 0;
        $self->value($value);
    }
    return;
}

=head2 calculate_payout

calculate contract value/payout

=cut

sub calculate_payout {
    my ($self) = @_;

    return financialrounding('price', $self->currency, $self->number_of_contracts * ($self->current_spot - $self->barrier->as_absolute));
}

=head2 _contract_price

calculate contract value

=cut

sub _contract_price {
    my ($self) = @_;

    return $self->_build_ask_probability->amount;
}

=head2 _check_barrier_crossed

check if the barrier was crossed

=cut

sub _check_barrier_crossed {
    my ($self, $spot) = @_;

    return ($spot <= $self->barrier->as_absolute);
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
