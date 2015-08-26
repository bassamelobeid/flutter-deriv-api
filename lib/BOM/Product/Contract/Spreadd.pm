package BOM::Product::Contract::Spreadd;

use Moose;
extends 'BOM::Product::Contract::Spread';
use Format::Util::Numbers qw(to_monetary_number_format roundnear);

use BOM::Product::Contract::Strike::Spread;
# Static methods

sub id              { return 260; }
sub code            { return 'SPREADD'; }
sub category_code   { return 'spreads'; }
sub display_name    { return 'spread down'; }
sub sentiment       { return 'down'; }
sub other_side_code { return 'SPREADU'; }
sub action          { return 'sell'; }

# The price of which the client bought at.
has barrier => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_barrier {
    my $self             = shift;
    my $supplied_barrier = $self->underlying->pipsized_value($self->entry_tick->quote - $self->half_spread);
    return BOM::Product::Contract::Strike::Spread->new(supplied_barrier => $supplied_barrier);
}

has [qw(stop_loss_level stop_profit_level)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_stop_loss_level {
    my $self = shift;
    return $self->underlying->pipsized_value($self->barrier->as_absolute + $self->stop_loss);
}

sub _build_stop_profit_level {
    my $self = shift;
    return $self->underlying->pipsized_value($self->barrier->as_absolute - $self->stop_profit);
}

has is_expired => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_is_expired {
    my $self = shift;

    my $is_expired = 0;
    my $tick       = $self->breaching_tick();
    if ($tick) {
        my $half_spread = $self->half_spread;
        my ($high_hit, $low_hit) =
            ($self->underlying->pipsized_value($tick->quote + $half_spread), $self->underlying->pipsized_value($tick->quote - $half_spread));
        my $stop_level;
        if ($low_hit <= $self->stop_profit_level) {
            $stop_level = $self->stop_profit_level;
        } elsif ($high_hit >= $self->stop_loss_level) {
            $stop_level = $self->stop_loss_level;
        }
        $is_expired = 1;
        $self->exit_level($stop_level);
        $self->_recalculate_value($stop_level);
    }

    return $is_expired;
}

has [qw(buy_level sell_level)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_buy_level {
    my $self = shift;
    return $self->underlying->pipsized_value($self->current_tick->quote - $self->half_spread);
}

sub _build_sell_level {
    my $self = shift;
    return $self->underlying->pipsized_value($self->current_tick->quote + $self->half_spread);
}

sub _recalculate_value {
    my ($self, $level) = @_;

    if ($level) {
        my $point_diff = roundnear(0.01, $self->barrier->as_absolute - $level);
        my $value = to_monetary_number_format($point_diff * $self->amount_per_point);
        $self->value($value);
        $self->point_value($point_diff);
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
    return [$self->stop_loss_level - $half_spread, $self->stop_profit_level + $half_spread];
}

sub localizable_description {
    return {
        dollar => 'Payout of [_1] [_2] for every point [_3] falls from entry level, with stop loss of [_6] [_4] and stop profit of [_6] [_5].',
        point =>
            'Payout of [_1] [_2] for every point [_3] falls from entry level, with stop loss of [plural,_4,%d point,%d points] and stop profit of [plural,_5,%d point,%d points].',
    };
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
