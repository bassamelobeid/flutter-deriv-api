package BOM::Product::Contract::Digitdiff;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::ExpireAtEnd';

use BOM::Platform::Context qw(localize);
use BOM::Product::Contract::Strike::Digit;
use BOM::Product::Pricing::Engine::Digits;
use BOM::Product::Pricing::Greeks::Digits;

# Static methods.
sub code { return 'DIGITDIFF'; }

sub localizable_description {
    return +{
        tick => '[_1] [_2] payout if the last digit of [_3] is not [_6] after [plural,_5,%d tick,%d ticks].',
    };
}

sub _build_ticks_to_expiry {
    return shift->tick_count;
}

sub _build_pricing_engine_name {
    return 'BOM::Product::Pricing::Engine::Digits';
}

sub _build_pricing_engine {
    return BOM::Product::Pricing::Engine::Digits->new({bet => shift});
}

sub _build_greek_engine {
    return BOM::Product::Pricing::Greeks::Digits->new({bet => shift});
}

sub _build_barrier {
    my $self = shift;

    if (not defined $self->supplied_barrier) {
        $self->add_error({
            severity          => 110,
            message           => 'supplied barrier for digits is undefined',
            message_to_client => localize('We could not process this contract at this time.'),
        });
        # setting supplied barrier to zero
        $self->supplied_barrier(0);
    }

    my $supp = $self->supplied_barrier + 0;    # make numeric
    return BOM::Product::Contract::Strike::Digit->new(supplied_barrier => $supp);
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
    return;    # override barrier validation
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
