package BOM::Product::Contract::Spreadup;

use Moose;
use Format::Util::Numbers qw(roundnear);
use BOM::Platform::Context qw(localize);
use BOM::Market::Underlying;

with 'MooseX::Role::Validatable';
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

has build_parameters => (
    is       => 'ro',
    isa      => 'HashRef',
    required => 1,
);

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

has [qw(stop_loss stop_profit spread)] => (
    is       => 'ro',
    isa      => 'PositiveNum',
    required => 1,
);

has current_tick => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_current_tick {
    my $self = shift;
    return $self->underlying->spot_tick;
}

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
    return roundnear(0.01, $self->stop_loss * $self->amount_per_point);
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
    my $current_tick = $self->current_tick;
    if ($current_tick) {
        my $current_sell_price = $current_tick->quote - $self->spread / 2;
        my $current_value      = ($current_sell_price - $self->strike) * $self->amount_per_point;
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

# On every spread contract, we will have both buy and sell quote.
# We call them 'buy_level' and 'sell_level' to avoid confusion with 'quote' in tick.
has [qw(buy_level sell_level)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_buy_level {
    my $self = shift;
    return $self->current_tick->quote + $self->spread / 2;
}

sub _build_sell_level {
    my $self = shift;
    return $self->current_tick->quote - $self->spread / 2;
}

has [qw(is_valid_to_buy is_valid_to_sell)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_is_valid_to_buy {
    my $self = shift;
    return $self->confirm_validity;
}

sub _build_is_valid_to_sell {
    my $self = shift;
    return $self->confirm_validity;
}

sub _validate_entry_tick {
    my $self = shift;

    my @err;
    if ($self->date_pricing->epoch - $self->underlying->max_suspend_trading_feed_delay->seconds > $self->current_tick->epoch) {
        push @err,
            {
            message           => 'Quote too old [' . $self->underlying->symbol . ']',
            severity          => 98,
            message_to_client => localize('Trading on [_1] is suspended due to missing market data.', $self->underlying->translated_display_name),
            };
    }
    return @err;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
