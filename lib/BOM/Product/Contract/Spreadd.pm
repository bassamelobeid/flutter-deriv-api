package BOM::Product::Contract::Spreadd;

use Moose;
extends 'BOM::Product::Contract::Spread';

use BOM::Product::Contract::Strike::Spread;
# Static methods

sub id              { return 260; }
sub code            { return 'SPREADD'; }
sub category_code   { return 'spreads'; }
sub display_name    { return 'spread down'; }
sub sentiment       { return 'down'; }
sub other_side_code { return 'SPREADU'; }

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

has [qw(stop_loss_price stop_profit_price)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_stop_loss_price {
    my $self = shift;
    return $self->underlying->pipsized_value($self->barrier->as_absolute + $self->stop_loss);
}

sub _build_stop_profit_price {
    my $self = shift;
    return $self->underying->pipsized_value($self->barrier->as_absolute - $self->stop_profit);
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
        if ($high >= $self->stop_loss_price) {
            $is_expired = 1;
            my $loss = $self->stop_loss * $self->amount_per_point;
            $self->value(-$loss);
        } elsif ($low <= $self->stop_profit_price) {
            $is_expired = 1;
            my $profit = $self->stop_profit * $self->amount_per_point;
            $self->value($profit);
        }
    }

    return $is_expired;
}

sub _recalculate_current_value {
    my ($self, $quote) = @_;

    return if $self->is_expired;
    if ($quote) {
        my $current_buy_price = $quote + $self->spread / 2;
        my $current_value     = ($self->barrier->as_absolute - $current_buy_price) * $self->amount_per_point;
        $self->value($current_value);
    }

    return;
}

# sell level
has level => (
    is         => 'ro',
    lazy_build => 1
);

sub _build_level {
    my $self = shift;
    return $self->current_tick->quote - $self->spread / 2;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
