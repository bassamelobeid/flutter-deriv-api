package BOM::Product::Contract::Spread;

use Moose;

use POSIX qw(fmod);
use Date::Utility;

use Format::Util::Numbers qw(roundnear);
use BOM::Platform::Context qw(localize request);
use BOM::Market::Underlying;

with 'MooseX::Role::Validatable';

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

has [qw(stop_loss stop_profit)] => (
    is       => 'rw',
    isa      => 'PositiveNum',
    required => 1,
);

# point or dollar amount
has stop_type => (
    is       => 'ro',
    required => 1,
);

#sub BUILD {
#    my $self = shift;
#
#    # possible initialization error
#    my $app = $self->amount_per_point;
#    if ($self->stop_type eq 'dollar_amount') {
#        my $err = (fmod($self->stop_loss, $app)) ? 'Stop-loss' : (fmod($self->stop_profit, $app)) ? 'Stop-profit' : undef;
#        if ($err) {
#            $self->add_errors({
#                    message           => 'stop_loss or stop_profit is not a multiple of amount_per_point.',
#                    severity          => 100,
#                    message_to_client => localize('[_1] must be a multiple of Amount per point.', $err),
#                };
#            );
#        } else {
#            # convert to point if no error.
#            $self->stop_loss($self->stop_loss / $app);
#            $self->stop_profit($self->stop_profit / $app);
#        }
#    }
#
#    return;
#}

has spread => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_spread {
    my $self = shift;
    return $self->underlying->base_spread;
}

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

sub current_value {
    my $self = shift;
    $self->_recalculate_current_value;
    return $self->value;
}

sub _get_highlow {
    my $self = shift;

    my ($high, $low) = @{
        $self->underlying->get_high_low_for_period({
                start => $self->entry_tick->epoch,
                end   => $self->date_pricing->epoch,
            })}{'high', 'low'};

    return ($high, $low);
}

# VALIDATIONS #
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
