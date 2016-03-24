package BOM::Product::Contract::Asianu;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::ExpireAtEnd';

use BOM::Product::Pricing::Engine::Asian;
use BOM::Product::Pricing::Greeks::Asian;

# Static methods.
sub code { return 'ASIANU'; }

sub localizable_description {
    return +{
        tick => '[_1] [_2] payout if the last tick of [_3] is strictly higher than the average of the [plural,_5,%d tick,%d ticks].',
    };
}

sub _build_ticks_to_expiry {
    return shift->tick_count;
}

sub _build_pricing_engine_name {
    return 'BOM::Product::Pricing::Engine::Asian';
}

sub _build_pricing_engine {
    return BOM::Product::Pricing::Engine::Asian->new({bet => shift});
}

sub _build_greek_engine {
    return BOM::Product::Pricing::Greeks::Asian->new({bet => shift});
}

has supplied_barrier => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_supplied_barrier {
    my $self = shift;

    my $hmt               = $self->tick_count;
    my @ticks_since_start = @{
        $self->underlying->ticks_in_between_start_limit({
                start_time => $self->date_start->epoch + 1,
                limit      => $hmt,
            })};
    my $supp;
    if (@ticks_since_start == $hmt and $hmt != 0) {
        my $sum = 0;
        map { $sum += $_->quote } @ticks_since_start;
        $supp = $sum / $hmt;
    }

    return $supp;
}

sub _build_barrier {
    my $self = shift;

    my $barrier;
    if ($self->supplied_barrier) {
        my $custom_pipsize = $self->underlying->pip_size / 10;
        $barrier = $self->make_barrier($self->supplied_barrier, {custom_pipsize => $custom_pipsize});
    }

    return $barrier;
}

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick) {
        my $value = ($self->exit_tick->quote > $self->barrier->as_absolute) ? $self->payout : 0;
        $self->value($value);
    }

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
