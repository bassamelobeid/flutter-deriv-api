package BOM::Product::LimitOrder;

use Moose;

use BOM::Product::Types;
use BOM::Product::Static;
use Scalar::Util::Numeric qw(isint);

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

sub BUILD {
    my $self = shift;

    if ($self->order_type eq 'stop_out' and not defined $self->order_amount) {
        die 'order_amount is required for type[' . $self->order_type . ']';
    }

    if (defined $self->order_amount) {
        my $order_amount         = $self->order_amount;
        my $precision_multiplier = 10**$self->order_precision;
        if ($order_amount == 0) {
            return $self->initialization_error({
                message           => 'order amount is zero for ' . $self->order_type,
                message_to_client => $ERROR_MAPPING->{ZeroOrderAmount},
            });
        } elsif (not isint($order_amount * $precision_multiplier)) {
            return $self->initialization_error({
                    message           => 'too many decimal places',
                    message_to_client => [
                        $ERROR_MAPPING->{
                              $self->order_type eq 'take_profit' ? 'TakeProfitIncorrectDecimal'
                            : $self->order_type eq 'stop_loss'   ? 'StopLossIncorrectDecimal'
                            :                                      ''
                        },
                        $self->order_precision
                    ],
                });
        }
    }

    if ($self->order_type eq 'take_profit') {
        my $amount = $self->order_amount;
        # capping take profit at 100 times of stake
        if (defined $amount and $amount > $self->ask_price * 100) {
            return $self->initialization_error({
                message           => 'take profit too high',
                message_to_client => $ERROR_MAPPING->{TakeProfitTooHigh},
            });
        }
    }

    return;
}

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

my %error_message_mapper = (
    stop_out    => 'InvalidStopOut',
    stop_loss   => 'InvalidStopLoss',
    take_profit => 'InvalidTakeProfit',
);

sub is_valid {
    my ($self, $current_pnl) = @_;

    # do not proceed if there's initialization error
    if ($self->initialization_error) {
        $self->validation_error($self->initialization_error);
        return 0;
    }

    die 'current pnl is undefined' unless defined $current_pnl;

    my $order_type   = $self->order_type;
    my $order_amount = $self->order_amount;

    if (((
                   $order_type eq 'stop_out'
                or $order_type eq 'stop_loss'
            )
            and $order_amount > $current_pnl
        )
        or ($order_type eq 'take_profit' and $order_amount < $current_pnl))
    {
        my $error = {
            message           => 'Invalid ' . $order_type . ' barrier',
            message_to_client => [$ERROR_MAPPING->{$error_message_mapper{$order_type}}, $current_pnl],
        };
        $self->validation_error($error);
        return 0;
    }

    return 1;
}

=head2 validation_error

validation error as hash reference

=cut

has [qw(validation_error initialization_error)] => (
    is       => 'rw',
    init_arg => undef,
    default  => undef,
);

no Moose;
__PACKAGE__->meta->make_immutable;

1;
