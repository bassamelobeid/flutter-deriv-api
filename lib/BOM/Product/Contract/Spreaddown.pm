package BOM::Product::Contract::Spreadup;

use Moose;
use Format::Util::Numbers qw(roundnear);

use BOM::Market::Underlying;

# Static methods

sub id              { return 260; }
sub code            { return 'SPREADDOWN'; }
sub category_code   { return 'spreads'; }
sub display_name    { return 'spread down'; }
sub sentiment       { return 'down'; }
sub other_side_code { return 'SPREADUP'; }

sub localizable_description {
    return 'You will win (lose) [_1] for every point that the [_2] rises (falls) from the entry spot.';
}

has amount_per_point => (
    is       => 'ro',
    isa      => 'PositiveNum',
    required => 1,
);

has underlying => (
    is       => 'ro',
    isa      => 'bom_underlying_object',
    coerce   => 1,
    required => 1,
);

has date_start => (
    is       => 'ro',
    isa      => 'bom_date_object',
    coerce   => 1,
    required => 1,
);

has date_pricing => (
    is      => 'ro',
    isa     => 'bom_date_object',
    coerce  => 1,
    default => sub { Date::Utility->new },
);

# the value of the position at close
has value => (
    is       => 'rw',
    init_arg => undef,
);

has [qw(stop_loss_point stop_profit_point spread)] => (
    is       => 'ro',
    isa      => 'PositiveNum',
    required => 1,
);

has entry_tick => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_entry_tick {
    my $self = shift;
    return $self->underlying->next_tick_after($self->date_start);
}

# The price of which the client bought at.
has strike => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_strike {
    my $self = shift;
    return $self->underlying->pipsized_value($self->entry_tick->quote - $self->spread / 2);
}

has [qw(stop_loss_price stop_profit_price)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_stop_loss_price {
    my $self = shift;
    return $self->strike + $self->stop_loss_point;
}

sub _build_stop_profit_price {
    my $self = shift;
    return $self->strike - $self->stop_profit_point;
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
            my $loss = $self->stop_loss_point * $self->amount_per_point;
            $self->value(-$loss);
        } elsif ($low <= $self->stop_profit_price) {
            $is_expired = 1;
            my $profit = $self->stop_profit_point * $self->amount_per_point;
            $self->value($profit);
        }
    }

    return $is_expired;
}

sub current_value {
    my $self = shift;
    $self->_recalculate_current_value;
    return $self->value;
}

has [qw(ask_price bid_price)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_ask_price {
    my $self = shift;
    return roundnear(0.01, $self->stop_loss_point * $self->amount_per_point);
}

sub _build_bid_price {
    my $self = shift;

    $self->_recalculate_current_value;
    # we need to take into account the stop loss premium paid.
    my $bid = $self->buy_price + $self->value;

    return roundnear(0.01, $bid);
}

sub _recalculate_current_value {
    my $self = shift;

    return if $self->is_expired;
    my $current_tick = $self->underlying->spot_tick;
    if ($current_tick) {
        my $current_buy_price = $current_tick->quote + $self->spread / 2;
        my $current_value      = ($self->strike - $current_buy_price) * $self->amount_per_point;
        $self->value($current_value);
    }

    return;
}

sub _get_highlow {
    my $self = shift;

    my ($high, $low);
    my $key = $self->entry_tick->epoch . '-' . $self->date_pricing->epoch;
    if (my $cache = $self->_cache->{$key}) {
        ($high, $low) = @{$cache}{'high', 'low'};
    } else {
        ($high, $low) = @{
            $self->underlying->get_high_low_for_period({
                    start => $self->entry_tick->epoch,
                    end   => $self->date_pricing->epoch,
                })}{'high', 'low'};
        $self->_cache->{$key} = {
            high => $high,
            low  => $low
            }
            if $high
            and $low;
    }

    return ($high, $low);
}

has _cache => (
    is      => 'rw',
    default => sub { {} },
);

no Moose;
__PACKAGE__->meta->make_immutable;
1;
