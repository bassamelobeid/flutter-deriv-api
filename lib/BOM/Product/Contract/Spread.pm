package BOM::Product::Contract::Spread;
use Time::HiRes qw(sleep);

use Moose;

use Date::Utility;
use BOM::Platform::Runtime;

use POSIX qw(floor);
use Math::Round qw(round);
use List::Util qw(min max);
use Scalar::Util qw(looks_like_number);
use BOM::Platform::Context qw(localize request);
use Format::Util::Numbers qw(roundnear);
use BOM::MarketData::Fetcher::VolSurface;
use BOM::Market::Data::Tick;
use BOM::Market::Underlying;
use BOM::Market::Types;

with 'MooseX::Role::Validatable';

# STATIC
# added for transaction validation
sub pricing_engine_name { return '' }
sub tick_expiry         { return 0 }
# added for CustomClientLimits
sub is_atm_bet { return 0 }
sub is_spread  { return 1 }

sub BUILD {
    my $self = shift;

    my $limits = {
        min => 1,
        max => 100
    };
    if ($self->amount_per_point < $limits->{min} or $self->amount_per_point > $limits->{max}) {
        $self->amount_per_point($limits->{min});    # set to minimum
        $self->add_errors({
            message  => 'amount_per_point[' . $self->amount_per_point . "] is not between [$limits->{min}] and [$limits->{max}]",
            severity => 99,
            message_to_client =>
                localize('Amount Per Point must be between [_1] and [_2] [_3].', $limits->{min}, $limits->{max}, $self->currency),
        });
    }

    return;
}

has build_parameters => (
    is       => 'ro',
    isa      => 'HashRef',
    required => 1,
);

has currency => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

# supplied_stop_loss & supplied_stop_profit can be in point or dollar amount
# we need the untouch input for longcode.
has [qw(supplied_stop_loss supplied_stop_profit stop_type)] => (
    is       => 'ro',
    required => 1,
);

has amount_per_point => (
    is       => 'rw',
    required => 1,
);

# stop_loss & stop_profit are only in point
has [qw(stop_profit stop_loss)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_stop_profit {
    my $self = shift;
    return $self->stop_type eq 'dollar' ? $self->supplied_stop_profit / $self->amount_per_point : $self->supplied_stop_profit;
}

sub _build_stop_loss {
    my $self = shift;
    return $self->stop_type eq 'dollar' ? $self->supplied_stop_loss / $self->amount_per_point : $self->supplied_stop_loss;
}

has underlying => (
    is       => 'ro',
    isa      => 'bom_underlying_object',
    coerce   => 1,
    required => 1,
    handles  => ['market', 'submarket'],
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

has [qw(date_expiry)] => (
    is  => 'ro',
    isa => 'bom_date_object',
    lazy_build => 1,
);

sub _build_date_expiry {
    my $self = shift;
    # Spread contracts do not have a fixed expiry.
    # But in our case, we set an expiry of 365d as the maximum holding time for a spread contract.
    return $self->date_start->plus_time_interval('365d');
}

# the value of the position at close
has [qw(value point_value)] => (
    is       => 'rw',
    init_arg => undef,
    default  => 0,
);

# spread_divisor - needed to reproduce the digit corresponding to one point
has [qw(spread spread_divisor spread_multiplier half_spread current_tick current_spot translated_display_name)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_spread {
    my $self = shift;

    my $vs = BOM::MarketData::Fetcher::VolSurface->new->fetch_surface({underlying => $self->underlying});
    # since it is only random indices
    my $vol     = $vs->get_volatility();
    my $spread  = $self->current_spot * sqrt($vol**2 * 2 / (365 * 86400)) * $self->spread_multiplier;
    my $y       = floor(log($spread) / log(10));
    my $x       = $spread / (10**$y);
    my $rounded = max(2, round($x / 2) * 2);

    return $rounded * 10**$y;
}

sub _build_spread_divisor {
    my $self = shift;
    return $self->underlying->spread_divisor;
}

sub _build_spread_multiplier {
    my $self = shift;
    return BOM::Platform::Runtime->instance->app_config->quants->commission->adjustment->spread_multiplier;
}

sub _build_half_spread {
    return shift->spread / 2;
}

sub _build_current_tick {
    my $self = shift;

    my $current_tick = $self->underlying->spot_tick;
    unless ($current_tick) {
        $current_tick = $self->_pip_size_tick;
        $self->add_errors({
            message           => 'Current tick is undefined for [' . $self->underlying->symbol . ']',
            severity          => 99,
            message_to_client => localize('Trading on [_1] is suspended due to missing market data.', $self->underlying->translated_display_name),
        });
    }

    return $current_tick;
}

sub _build_current_spot {
    my $self = shift;
    return $self->current_tick ? $self->current_tick->quote : undef;
}

sub _build_translated_display_name {
    my $self = shift;

    return unless ($self->display_name);
    return localize($self->display_name);
}

has exit_level => (is => 'rw');

has entry_tick => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_entry_tick {
    my $self = shift;

    my $entry_tick;
    my $hold_seconds  = 5;                      # 5 seconds of hold time
    my $max_hold_time = time + $hold_seconds;
    do {
        $entry_tick = $self->underlying->next_tick_after($self->date_start->epoch);
    } while (not $entry_tick and sleep(0.5) and time <= $max_hold_time);

    if (not $entry_tick) {
        $entry_tick = $self->current_tick // $self->_pip_size_tick;
        $self->add_errors({
            message           => 'Entry tick is undefined for [' . $self->underlying->symbol . ']',
            severity          => 99,
            message_to_client => localize('Trading on [_1] is suspended due to missing market data.', $self->underlying->translated_display_name),
        });
    }

    return $entry_tick;
}

has ask_price => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_ask_price {
    my $self = shift;
    return roundnear(0.01, $self->stop_loss * $self->amount_per_point);
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

has [qw(is_valid_to_buy is_valid_to_sell may_settle_automatically)] => (
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

sub _build_may_settle_automatically {
    my $self = shift;
    return $self->is_valid_to_sell;
}

has [qw(shortcode longcode)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_shortcode {
    my $self = shift;
    my @element = map { uc $_ } (
        $self->code, $self->underlying->symbol,
        $self->amount_per_point, $self->date_start->epoch,
        $self->supplied_stop_loss, $self->supplied_stop_profit,
        $self->stop_type
    );
    return join '_', @element;
}

sub _build_longcode {
    my $self        = shift;
    my $description = $self->localizable_description->{$self->stop_type};
    my @other       = ($self->supplied_stop_loss, $self->supplied_stop_profit);

    if ($self->stop_type eq 'dollar') {
        push @other, $self->currency;
    }

    return localize($description, ($self->currency, $self->amount_per_point, $self->underlying->translated_display_name, @other));
}

sub breaching_tick {
    my $self = shift;

    my $start = $self->entry_tick->epoch > $self->date_pricing->epoch ? $self->date_start->epoch + 1 : $self->entry_tick->epoch;
    # we use the original high/low here because the feed DB stores mid instead of buy/sell.
    my ($higher_barrier, $lower_barrier) = @{$self->_highlow_args};
    my $tick = $self->underlying->breaching_tick((
        start_time => $start,
        end_time   => $self->date_pricing->epoch,
        higher     => $higher_barrier,
        lower      => $lower_barrier
    ));

    return $tick;
}

has _pip_size_tick => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build__pip_size_tick {
    my $self = shift;

    return BOM::Market::Data::Tick->new({
        quote  => $self->underlying->pip_size,
        epoch  => 1,                             # Intentionally very old for recognizability.
        symbol => $self->underlying->symbol,
    });
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

has is_expired => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_is_expired {
    my $self = shift;

    my $is_expired = 0;
    my $tick       = $self->breaching_tick();
    if ($self->date_pricing->is_after($self->date_expiry)) {
        $is_expired = 1;
        $self->exit_level($self->sell_level);
        $self->_recalculate_value($self->sell_level);
    } elsif ($tick) {
        my $half_spread = $self->half_spread;
        my ($high_hit, $low_hit) =
            ($self->underlying->pipsized_value($tick->quote + $half_spread), $self->underlying->pipsized_value($tick->quote - $half_spread));
        my $stop_level = $self->_get_hit_level($high_hit, $low_hit);
        $is_expired = 1;
        $self->exit_level($stop_level);
        $self->_recalculate_value($stop_level);
    }

    return $is_expired;
}


sub current_value {
    my $self = shift;
    $self->_recalculate_value($self->sell_level);
    return {
        dollar => $self->value,
        point  => $self->point_value,
    };
}

# VALIDATIONS #
sub _validate_quote {
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

sub _validate_underlying {
    my $self = shift;

    my @err;
    # we only allow random index for now.
    if ($self->underlying->submarket->name ne 'random_index') {
        push @err,
            {
            message           => 'Invalid underlying for spread[' . $self->underlying->symbol . ']',
            severity          => 98,
            message_to_client => localize('Trading on [_1] is not offered for this contract type.', $self->underlying->translated_display_name),
            };
    }

    if (not $self->underlying->exchange->is_open) {
        push @err,
            {
            message           => 'Market is closed [' . $self->underlying->symbol . ']',
            severity          => 98,
            message_to_client => localize(
                "This market is presently closed. <a href='[_1]'>View Trading Times</a> or try out the <a href='[_2]'>Random Indices</a> which are always open.",
                request()->url_for('/resources/trading_times', undef, {no_host => 1}),
                request()->url_for('trade.cgi', {market => "random"})
            ),
            };
    }
    return @err;
}

sub _validate_stop_loss {
    my $self = shift;

    my @err;
    my $limits = {
        min => 1.5 * $self->spread,
        max => $self->current_spot
    };
    if ($self->stop_loss < $limits->{min} or $self->stop_loss > $limits->{max}) {
        my ($min, $max, $unit) = $self->_get_min_max_unit(@{$limits}{'min', 'max'});
        my $message_to_client = localize('Stop Loss must be between [_1] and [_2] [_3]', $min, $max, $unit);
        push @err,
            {
            message           => "Stop Loss is not between [$limits->{min}] and [$limits->{max}]",
            severity          => 99,
            message_to_client => $message_to_client,
            };
    }

    return @err;
}

sub _validate_stop_profit {
    my $self = shift;

    my @err;
    my $limits = {
        min => 1,
        max => min($self->stop_loss * 5, 1000 / $self->amount_per_point)};
    if ($self->stop_profit < $limits->{min} or $self->stop_profit > $limits->{max}) {
        my ($min, $max, $unit) = $self->_get_min_max_unit(@{$limits}{'min', 'max'});
        my $message_to_client = localize('Stop Profit must be between [_1] and [_2] [_3]', $min, $max, $unit);
        push @err,
            {
            message           => "Stop Profit is not between [$limits->{min}] and [$limits->{max}]",
            severity          => 99,
            message_to_client => $message_to_client,
            };
    }

    return @err;
}

sub _get_min_max_unit {
    my ($self, $min, $max) = @_;
    my $unit;
    if ($self->stop_type eq 'dollar') {
        $unit = $self->currency;
        $min *= $self->amount_per_point;
        $max *= $self->amount_per_point;
    } else {
        $unit = 'points';
    }

    return (roundnear(0.01, $min), roundnear(0.01, $max), $unit);
}
no Moose;
__PACKAGE__->meta->make_immutable;
1;
