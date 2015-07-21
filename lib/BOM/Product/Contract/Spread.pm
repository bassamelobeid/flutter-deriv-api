package BOM::Product::Contract::Spread;
use Time::HiRes qw(sleep);

use Moose;

use Date::Utility;
use BOM::Platform::Runtime;

use List::Util qw(min);
use Scalar::Util qw(looks_like_number);
use BOM::Product::Offerings qw( get_contract_specifics );
use Format::Util::Numbers qw(to_monetary_number_format roundnear);
use BOM::Platform::Context qw(localize request);
use BOM::Market::Data::Tick;
use BOM::Market::Underlying;
use BOM::Market::Types;

with 'MooseX::Role::Validatable';

sub BUILD {
    my $self = shift;

    # stop_loss, stop_profit, amount_per_point has to be greater than zero.
    if ($self->stop_loss <= 0 or $self->stop_profit <= 0 or $self->amount_per_point <= 0) {
        $self->add_errors({
            message => 'Negative entry on stop_loss['
                . $self->stop_loss
                . '] or stop_profit['
                . $self->stop_profit
                . '] or amount_per_point['
                . $self->amount_per_point . ']',
            severity          => 99,
            message_to_client => localize('Stop Loss, Stop Profit and Amount Per Point must be greater than zero.'),
        });
    }

    return;
}

# STATIC
# added for transaction validation
sub pricing_engine_name { return '' }
sub tick_expiry         { return 0 }
# added for CustomClientLimits
sub is_atm_bet { return 0 }
sub is_spread  { return 1 }

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

has [qw(stop_type stop_loss stop_profit amount_per_point)] => (
    is       => 'rw',
    required => 1,
);

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
    isa => 'Maybe[bom_date_object]',
);

# the value of the position at close
has [qw(value point_value)] => (
    is       => 'rw',
    init_arg => undef,
    default  => 0,
);

# spread_divisor - needed to reproduce the digit corresponding to one point
has [qw(spread spread_divisor half_spread current_tick current_spot translated_display_name)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_spread {
    my $self = shift;
    return $self->underlying->base_spread;
}

sub _build_spread_divisor {
    my $self = shift;
    return $self->underlying->spread_divisor;
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
    return shift->current_tick->quote;
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
    my $ask = $self->stop_type eq 'dollar' ? $self->stop_loss : $self->stop_loss * $self->amount_per_point;
    return roundnear(0.01, $ask);
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
        $self->stop_loss, $self->stop_profit, $self->stop_type
    );
    return join '_', @element;
}

sub _build_longcode {
    my $self        = shift;
    my $description = $self->longcode_description;
    my @other       = ($self->stop_loss, $self->stop_profit);
    if ($self->stop_type eq 'dollar') {
        push @other, $self->currency;
        $description .= ' with stop loss of <strong>[_6] [_4]</strong> and limit of <strong>[_6] [_5]</strong>.';
    } else {
        push @other, 'points';
        $description .= ' with stop loss of <strong>[_4] [_6]</strong> and limit of <strong>[_5] [_6]</strong>.';
    }

    return localize($description, ($self->currency, $self->amount_per_point, $self->underlying->translated_display_name, @other));
}

has 'staking_limits' => (
    is         => 'ro',
    isa        => 'HashRef',
    lazy_build => 1,
);

sub _build_staking_limits {
    my $self = shift;

    my $underlying     = $self->underlying;
    my $contract_specs = get_contract_specifics({
        underlying_symbol => $underlying->symbol,
        contract_category => $self->category_code,
        expiry_type       => 'intraday',                                                                  # hardcoded
        start_type        => 'spot',                                                                      #hardcoded
        barrier_category  => $BOM::Product::Offerings::BARRIER_CATEGORIES->{$self->category_code}->[0],
    });

    my @possible_payout_maxes = ($contract_specs->{payout_limit});

    push @possible_payout_maxes, BOM::Platform::Runtime->instance->app_config->quants->bet_limits->maximum_payout;
    push @possible_payout_maxes, BOM::Platform::Runtime->instance->app_config->quants->bet_limits->maximum_payout_on_new_markets
        if ($underlying->is_newly_added);

    my $payout_max = min(grep { looks_like_number($_) } @possible_payout_maxes);
    my $stake_max = $payout_max;

    my $payout_min = 1;
    my $stake_min  = $payout_min / 2;

    # err is included here to allow the web front-end access to the same message generated in the back-end.
    return {
        stake => {
            min => $stake_min,
            max => $stake_max,
            err => localize(
                'Stake must be between <strong>[_1]</strong> and <strong>[_2]</strong>.',
                to_monetary_number_format($stake_min, 1),
                to_monetary_number_format($stake_max, 1)
            ),
        },
        payout => {
            min => $payout_min,
            max => $payout_max,
            err => localize(
                'Payout must be between <strong>[_1]</strong> and <strong>[_2]</strong>.',
                to_monetary_number_format($payout_min, 1),
                to_monetary_number_format($payout_max, 1)
            ),
        },
    };
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

# VALIDATIONS #
sub _validate_stop_profit {
    my $self = shift;

    my @err;
    if ($self->stop_loss * 5 < $self->stop_profit) {
        push @err,
            {
            message           => 'Stop profit [' . $self->stop_profit . '] is too high compared to stop loss [' . $self->stop_loss . ']',
            severity          => 88,
            message_to_client => localize('Stop profit cannot be higher than 5 times the stop loss.'),
            };
    }
    return @err;
}

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
            message_to_client => localize('This market is presently closed.')
                . " <a href="
                . request()->url_for('/resources/trading_times', undef, {no_host => 1}) . ">"
                . localize('View Trading Times') . "</a> "
                . localize(
                "or try out the <a href='[_1]'>Random Indices</a> which are always open.",
                request()->url_for('trade.cgi', {market => "random"})
                ),
            };
    }
    return @err;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
