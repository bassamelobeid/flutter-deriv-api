package BOM::Product::Contract::Spreadu;

use Moose;
extends 'BOM::Product::Contract::Spread';
use Format::Util::Numbers qw(to_monetary_number_format roundnear);

use BOM::Platform::Context qw(localize);
use BOM::Product::Contract::Strike::Spread;

# Static methods
sub code   { return 'SPREADU'; }
sub action { return 'buy'; }

# The price of which the client bought at.
has barrier => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_barrier {
    my $self             = shift;
    my $supplied_barrier = $self->underlying->pipsized_value($self->entry_tick->quote + $self->half_spread);
    return BOM::Product::Contract::Strike::Spread->new(supplied_barrier => $supplied_barrier);
}

has [qw(stop_loss_level stop_profit_level)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_stop_loss_level {
    my $self = shift;
    return $self->underlying->pipsized_value($self->barrier->as_absolute - $self->stop_loss);
}

sub _build_stop_profit_level {
    my $self = shift;
    return $self->underlying->pipsized_value($self->barrier->as_absolute + $self->stop_profit);
}

sub _get_hit_level {
    my ($self, $high_hit, $low_hit) = @_;

    my $stop_level;
    if ($high_hit >= $self->stop_profit_level) {
        $stop_level = $self->stop_profit_level;
    } elsif ($low_hit <= $self->stop_loss_level) {
        $stop_level = $self->stop_loss_level;
    }

    return $stop_level;
}

has [qw(buy_level sell_level)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_buy_level {
    my $self = shift;
    return $self->underlying->pipsized_value($self->current_tick->quote + $self->half_spread);
}

sub _build_sell_level {
    my $self = shift;
    return $self->underlying->pipsized_value($self->current_tick->quote - $self->half_spread);
}

sub _recalculate_value {
    my ($self, $level) = @_;

    if ($level) {
        my $point_diff = $level - $self->barrier->as_absolute;
        my $value      = $point_diff * $self->amount_per_point;
        $self->value(roundnear(0.01, $value));
        $self->point_value($self->underlying->pipsized_value($point_diff));
    }

    return;
}

has _highlow_args => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build__highlow_args {
    my $self        = shift;
    my $half_spread = $self->half_spread;
    return [$self->stop_profit_level + $half_spread, $self->stop_loss_level + $half_spread];
}

sub localizable_description {
    return {
        dollar => '[_1] [_2] payout for every point [_3] rises from entry level, with stop loss of [_6] [_4] and stop profit of [_6] [_5].',
        point  => '[_1] [_2] payout for every point [_3] rises from entry level, with stop loss of [_4] points and stop profit of [_5] points.',
    };
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
