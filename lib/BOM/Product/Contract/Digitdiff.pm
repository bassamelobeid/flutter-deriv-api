package BOM::Product::Contract::Digitdiff;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Binary', 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::ExpireAtEnd';

use Pricing::Engine::Digits;
use Scalar::Util qw(looks_like_number);
use BOM::Product::Contract::Strike::Digit;
use BOM::Product::Pricing::Greeks::ZeroGreek;

sub ticks_to_expiry {
    return shift->tick_count;
}

sub _build_pricing_engine_name {
    return 'Pricing::Engine::Digits';
}

sub _build_greek_engine {
    return BOM::Product::Pricing::Greeks::ZeroGreek->new({bet => shift});
}

sub _build_barrier {
    my $self = shift;

    return BOM::Product::Exception->throw(
        error_code => 'MissingRequiredDigit',
        details    => {field => 'barrier'},
    ) if (not looks_like_number($self->supplied_barrier));

    return BOM::Product::Contract::Strike::Digit->new(supplied_barrier => $self->supplied_barrier);
}

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick) {
        # This is overly defensive, but people keep brekaing the pipsized, assumption
        my $last_digit = (split //, $self->underlying->pipsized_value($self->exit_tick->quote))[-1];
        my $value = ($last_digit != $self->barrier->as_absolute) ? $self->payout : 0;
        $self->value($value);
    }

    return;
}

sub _validate_barrier {
    my $self = shift;

    return $self->barrier->primary_validation_error unless ($self->barrier->confirm_validity);

    return;    # override barrier validation
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
