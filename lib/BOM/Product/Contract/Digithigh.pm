package BOM::Product::Contract::Digithigh;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Binary', 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::ExpireAtEnd';

use List::Util qw/max/;
use List::MoreUtils qw/first_index/;

use Pricing::Engine::Digits;

use BOM::Product::Contract::Strike::Digit;
use BOM::Product::Pricing::Greeks::Digits;

has selected_tick {
    is       => 'ro',
    required => 1,
    }

    sub ticks_to_expiry {
    return 5;
}

sub _build_pricing_engine_name {
    return 'Pricing::Engine::Digits';
}

sub _build_greek_engine {
    return BOM::Product::Pricing::Greeks::Digits->new({bet => shift});
}

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick) {
        my $ticks = $self->underlying->ticks_in_between_start_limit({
            start_time => $self->date_start,
            limit      => 5
        });
        my $max = max(map { $_->{quote} } @$ticks);
        my $max_index = first_index { $_->{quote} == $max } @$ticks;
        my $contract_value = ($self->selected_tick == $max_index + 1) ? $self->payout : 0;

        $self->value($contract_value);
    }

    return undef;
}

sub _validate_barrier {
    return;    # override barrier validation
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
