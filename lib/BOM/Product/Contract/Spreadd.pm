package BOM::Product::Contract::Spreadd;

use Moose;
extends 'BOM::Product::Contract::Spread';
use Format::Util::Numbers qw(roundnear);

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
    my $supplied_barrier = $self->underlying->pipsized_value($self->entry_tick->quote - $self->spread / 2);
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
        my $hit_quote = $self->underlying->pipsized_value($tick->quote - $self->spread / 2);
        my $stop_level;
        if ($hit_quote <= $self->stop_profit_level) {
            $stop_level = $self->stop_profit_level;
        } elsif ($hit_quote >= $self->stop_loss_level) {
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
        $self->exit_level($self->buy_level);
        $self->_recalculate_value($self->buy_level);
        $bid = $self->ask_price + $self->value;
    }

    return roundnear(0.01, $bid);
}

has stream_level => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_stream_level {
    return shift->sell_level;
}

sub _recalculate_value {
    my ($self, $level) = @_;

    if ($level) {
        my $value = ($self->barrier->as_absolute - $level) * $self->amount_per_point;
        $self->value($value);
    }

    return;
}

sub current_value {
    my $self = shift;
    $self->_recalculate_value($self->buy_level);
    return $self->value;
}

has _highlow_args => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build__highlow_args {
    my $self  = shift;
    my $entry = $self->entry_tick->quote;
    return [$entry + $self->stop_loss, $entry - $self->stop_profit];
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
