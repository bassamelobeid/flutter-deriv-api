package BOM::Product::Contract::Digitunder;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::ExpireAtEnd';

use BOM::Platform::Context qw(localize);
use BOM::Product::Contract::Strike::Digit;
use BOM::Product::Pricing::Engine::Digits;
use BOM::Product::Pricing::Greeks::Digits;

sub code { return 'DIGITUNDER'; }

sub localizable_description {
    return +{
        tick => '[_1] [_2] payout if the last digit of [_3] is strictly lower than [_6] after [_5] ticks.',
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
    my $supp = $self->supplied_barrier + 0;    # make numeric
    return BOM::Product::Contract::Strike::Digit->new(supplied_barrier => $supp);
}

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick) {
        # This is overly defensive, but people keep brekaing the pipsized, assumption
        my $last_digit = (split //, $self->underlying->pipsized_value($self->exit_tick->quote))[-1];
        my $value = ($last_digit < $self->barrier->as_absolute) ? $self->payout : 0;
        $self->value($value);
    }

    return;
}

sub _validate_barrier {
    my $self = shift;

    # check for barrier validity here.
    my $barrier        = $self->barrier->as_absolute;
    my @barrier_range  = (1 .. 9);
    my %valid_barriers = map { $_ => 1 } @barrier_range;

    if (not $valid_barriers{$barrier}) {
        return {
            severity => 100,
            message  => 'No winning digits ' . "[code: " . $self->code . "] " . "[selection: " . $barrier . "]",
            message_to_client => localize('Digit must be in the range of [_1] to [_2].', $barrier_range[0], $barrier_range[-1]),
        };
    }

    return;    # override barrier validation
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
