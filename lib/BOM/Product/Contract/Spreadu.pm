package BOM::Product::Contract::Spreadu;

use Moose;
extends 'BOM::Product::Contract::Spread';
use Format::Util::Numbers qw(roundnear);

use BOM::Product::Contract::Strike::Spread;

# Static methods
sub id              { return 250; }
sub code            { return 'SPREADU'; }
sub category_code   { return 'spreads'; }
sub display_name    { return 'spread up'; }
sub sentiment       { return 'up'; }
sub other_side_code { return 'SPREADD'; }
sub action          { return 'buy'; }

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
    my $stop_loss_point = $self->stop_type eq 'dollar' ? $self->stop_loss / $self->amount_per_point : $self->stop_loss;
    return $self->underlying->pipsized_value($self->barrier->as_absolute - $stop_loss_point);
}

sub _build_stop_profit_level {
    my $self = shift;
    my $stop_profit_point = $self->stop_type eq 'dollar' ? $self->stop_profit / $self->amount_per_point : $self->stop_profit;
    return $self->underlying->pipsized_value($self->barrier->as_absolute + $stop_profit_point);
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
        if ($high_hit >= $self->stop_profit_level) {
            $stop_level = $self->stop_profit_level;
        } elsif ($low_hit <= $self->stop_loss_level) {
            $stop_level = $self->stop_loss_level;
        }
        $is_expired = 1;
        $self->exit_level($stop_level);
        $self->_recalculate_value($stop_level);
    }

    return $is_expired;
}

has bid_price => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_bid_price {
    my $self = shift;

    my $bid;
    # we need to take into account the stop loss premium paid.
    if ($self->is_expired) {
        $bid = $self->ask_price + $self->value;
    } else {
        $self->exit_level($self->sell_level);
        $self->_recalculate_value($self->sell_level);
        $bid = $self->ask_price + $self->value;
    }

    return roundnear(0.01, $bid);
}

has stream_level => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_stream_level {
    return shift->buy_level;
}

sub _recalculate_value {
    my ($self, $level) = @_;

    if ($level) {
        my $point_diff = roundnear(0.01, $level - $self->barrier->as_absolute);
        my $value = $point_diff * $self->amount_per_point;
        $self->value($value);
        $self->point_value($point_diff);
    }

    return;
}

sub current_value {
    my $self = shift;
    $self->_recalculate_value($self->sell_level);
    return {
        dollar => $self->value,
        point  => $self->point_value,
    };
}

has _highlow_args => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build__highlow_args {
    my $self        = shift;
    my $half_spread = $self->half_spread;
    return [$self->stop_profit_level - $half_spread, $self->stop_loss_level + $half_spread];
}

has longcode_description => (
    is      => 'ro',
    default => 'You will win (lose) [_1] <strong>[_2]</strong> for every point that the [_3] <strong>rises (falls)</strong> from the <strong>entry spot</strong>,',
);

no Moose;
__PACKAGE__->meta->make_immutable;
1;
