package BOM::Product::Contract::Onetouch;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Binary', 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::AmericanExpiry';

use BOM::Product::Exception;

sub ticks_to_expiry {
    my $self = shift;

    return BOM::Product::Exception->throw(
        error_code => 'InvalidTickExpiry',
        error_args => [$self->code],
    );
}

sub check_expiry_conditions {
    my $self = shift;

    my ($high, $low, $expired) = $self->get_high_low_for_contract_period();
    if (defined $high and defined $low) {
        my $barrier = $self->barrier->as_absolute;
        my $value   = 0;
        if ($high >= $barrier && $low <= $barrier) {
            $value   = $self->payout;
            $expired = 1;
        } elsif ($expired) {
            $value = 0;
        }
        $self->value($value);
    }

    return $expired;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
