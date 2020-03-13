package BOM::Product::LimitOrder;

use Moose;

use BOM::Product::Exception;
use BOM::Product::Types;
use BOM::Product::Static;
use List::Util qw(max min);
use Scalar::Util::Numeric qw(isint);
use Format::Util::Numbers qw(financialrounding);

use constant MIN_ORDER_AMOUNT => 0.1;

my $ERROR_MAPPING = BOM::Product::Static::get_error_mapping();

=head1 NAME

BOM::Product::LimitOrder - a representation of stop loss or take profit for multiplier contract.

=cut

=head2 order_type

type of limit order. E.g. stop_loss or take_profit

=head2 basis_spot

Limit order is placed with dollar amount.

We need basis spot to convert it to a barrier value.

=head2 order_date

The date when the order is placed.

=head2 order_amount

The dollar amount of the order placed

=cut

has order_amount => (
    is      => 'ro',
    default => undef
);

has [qw(order_type basis_spot)] => (
    is       => 'ro',
    required => 1,
);

has order_date => (
    is       => 'ro',
    isa      => 'date_object',
    coerce   => 1,
    required => 1,
);

# Since we can't make limit order independent of the main contract, we will need
# to live with these.
has [qw(commission multiplier sentiment ask_price underlying order_precision)] => (
    is       => 'ro',
    required => 1,
);

=head2 barrier_value

A non pip-sized barrier value calculated from $self->basis_spot

=cut

sub barrier_value {
    my $self = shift;

    return undef unless $self->order_amount;

    my $sentiment_multiplier = $self->sentiment eq 'up' ? 1 : -1;
    my $commission = $self->commission // 0;
    my $barrier_value =
        ($self->order_amount / ($self->multiplier * $self->ask_price) + $commission) * $sentiment_multiplier * $self->basis_spot + $self->basis_spot;

    return $self->underlying->pipsized_value($barrier_value);
}

=head2 is_valid

Validate if the limit order placed is valid.

=cut

sub is_valid {
    my ($self, $current_pnl, $currency, $pricing_new) = @_;

    $pricing_new //= 0;
    # undef if we want to cancel and it should always be valid
    unless (defined $self->order_amount) {
        return 1;
    }

    if (my $decimal_error = $self->_subvalidate_decimal) {
        $self->validation_error($decimal_error);
        return 0;
    }

    die 'current pnl is undefined' unless defined $current_pnl;

    my $validation_method = '_validate_' . $self->order_type;
    if (my $error = $self->$validation_method($current_pnl, $currency, $pricing_new)) {
        $self->validation_error($error);
        return 0;
    }

    return 1;
}

sub _validate_stop_out {
    my ($self, $current_pnl, $currency) = @_;

    my $amount = $self->order_amount;
    unless (defined $amount) {
        die 'order_amount is required for type[' . $self->order_type . ']';
    }

    if ($amount >= $current_pnl) {
        return {
            message           => 'stop out lower than pnl',
            message_to_client => [$ERROR_MAPPING->{InvalidStopOut}, financialrounding('price', $currency, abs($current_pnl))],
            details => {feild => $self->order_type},
        };
    }

    return 0;
}

sub _validate_stop_loss {
    my ($self, $current_pnl, $currency, $pricing_new) = @_;

    my $amount = $self->order_amount;
    my $details = {field => $self->order_type};
    # check minimum allowed
    if ($amount > -MIN_ORDER_AMOUNT) {
        return {
            message           => 'stop loss too low',
            message_to_client => [$ERROR_MAPPING->{InvalidStopLoss}, financialrounding('price', $currency, MIN_ORDER_AMOUNT)],
            details           => $details,
        };
    }

    # capping stop loss at stake amount
    if (defined $amount and abs($amount) > $self->ask_price) {
        return {
            message           => 'stop loss too high',
            message_to_client => $ERROR_MAPPING->{StopLossTooHigh},
            details           => $details,
        };
    }

    my $error_string = $pricing_new ? 'InvalidInitialStopLoss' : 'InvalidStopLoss';

    # A floating pnl could be positive. Hence, we need to keep the value below zero.
    $current_pnl = min(0, $current_pnl);
    if ($amount >= $current_pnl) {
        return {
            message           => 'stop loss lower than pnl',
            message_to_client => [$ERROR_MAPPING->{$error_string}, financialrounding('price', $currency, abs($current_pnl))],
            details           => $details,
        };
    }

    return 0;
}

sub _validate_take_profit {
    my ($self, $current_pnl, $currency) = @_;

    my $amount = $self->order_amount;
    my $details = {field => $self->order_type};
    # check minimum allowed
    if ($amount < MIN_ORDER_AMOUNT) {
        return {
            message           => 'take profit too low',
            message_to_client => [$ERROR_MAPPING->{InvalidTakeProfit}, financialrounding('price', $currency, MIN_ORDER_AMOUNT)],
            details           => $details,
        };
    }

    # 90% (because of commission) of multiplier or 50.
    my $max_amount = min(0.9 * $self->multiplier, 50);
    if (defined $amount and $amount / $self->ask_price > $max_amount) {
        BOM::Product::Exception->throw(
            error_code => 'TakeProfitTooHigh',
            error_args => [financialrounding('price', $currency, $max_amount * $self->ask_price)],
            details => {field => 'take_profit'},
        );
    }

    # A floating pnl could be negative. Hence, we need to keep the value above zero.
    my $pnl = max(0, $current_pnl);
    if ($amount <= $pnl) {
        return {
            message           => 'take profit lower than pnl',
            message_to_client => [$ERROR_MAPPING->{InvalidTakeProfit}, financialrounding('price', $currency, $pnl)],
            details           => $details,
        };
    }

    return;
}

sub _subvalidate_decimal {
    my $self = shift;

    my $precision_multiplier = 10**$self->order_precision;

    unless (isint($self->order_amount * $precision_multiplier)) {
        return {
            message           => 'too many decimal places',
            message_to_client => [$ERROR_MAPPING->{LimitOrderIncorrectDecimal}, $self->order_precision],
            details           => {field => $self->order_type},
        };
    }

    return;
}

=head2 validation_error

validation error as hash reference

=cut

has [qw(validation_error)] => (
    is       => 'rw',
    init_arg => undef,
    default  => undef,
);

no Moose;
__PACKAGE__->meta->make_immutable;

1;
