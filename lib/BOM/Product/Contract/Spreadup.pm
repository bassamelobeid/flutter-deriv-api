package BOM::Product::Contract::Spreadup;

use Moose;
extends 'BOM::Product::Contract::Spread';

# Static methods
sub id              { return 250; }
sub code            { return 'SPREADUP'; }
sub category_code   { return 'spread'; }
sub display_name    { return 'spread up'; }
sub sentiment       { return 'up'; }
sub other_side_code { return 'SPREADDOWN'; }

sub localizable_description {
    return 'You will win (lose) [_1] for every point that the [_2] rises (falls) from the entry spot.';
}

# The price of which the client bought at.
has strike => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_strike {
    my $self = shift;
    return $self->underlying->pipsized_value($self->entry_tick->quote + $self->spread / 2);
}

has [qw(stop_loss_price stop_profit_price)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_stop_loss_price {
    my $self = shift;
    return $self->strike - $self->stop_loss;
}

sub _build_stop_profit_price {
    my $self = shift;
    return $self->strike + $self->stop_profit;
}

has is_expired => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_is_expired {
    my $self = shift;

    my ($high, $low) = $self->_get_highlow({
        from => $self->entry_tick->epoch,
        to   => $self->date_pricing->epoch,
    });

    my $is_expired = 0;
    if ($high and $low) {
        if ($low <= $self->stop_loss_price) {
            $is_expired = 1;
            my $loss = $self->stop_loss * $self->amount_per_point;
            $self->value(-$loss);
        } elsif ($high >= $self->stop_profit_price) {
            $is_expired = 1;
            my $profit = $self->stop_profit * $self->amount_per_point;
            $self->value($profit);
        }
    }

    return $is_expired;
}

sub _recalculate_current_value {
    my $self = shift;

    return if $self->is_expired;
    my $current_tick = $self->current_tick;
    if ($current_tick) {
        my $current_sell_price = $current_tick->quote - $self->spread / 2;
        my $current_value      = ($current_sell_price - $self->strike) * $self->amount_per_point;
        $self->value($current_value);
    }

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
