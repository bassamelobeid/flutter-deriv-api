package BOM::Transaction::ContractUpdate;

use Moo;

use BOM::Platform::Context qw(localize);
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::Helper::FinancialMarketBet;

use Scalar::Util qw(looks_like_number);
use BOM::Transaction;
use Finance::Contract::Longcode qw(shortcode_to_parameters);
use BOM::Product::ContractFactory qw(produce_contract);
use ExpiryQueue qw(enqueue_open_contract dequeue_open_contract);

=head1 NAME

BOM::Transaction::ContractUpdate - contains methods to update a contract

=cut

=head2 client

The owner of the contract

=head2 contract_id

The unique id to identify a financial_market_bet.

=head2 validation_error

A hash reference that has code (error code) and message_to_client, if any.

=cut

has client => (
    is       => 'ro',
    required => 1,
);

has contract_id => (
    is       => 'ro',
    required => 1,
);

has update_params => (
    is       => 'ro',
    required => 1,
);

has [qw(fmb validation_error)] => (
    is       => 'rw',
    init_arg => undef,
    default  => undef,
);

has contract => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_contract',
);

sub _build_contract {
    my $self = shift;

    my $fmb_dm = BOM::Database::DataMapper::FinancialMarketBet->new(
        broker_code => $self->client->broker_code,
        operation   => 'replica',
    );

    # fmb reference with buy_transantion transaction ids (buy or buy and sell)
    my $fmb = $fmb_dm->get_contract_details_with_transaction_ids($self->contract_id)->[0];

    return undef unless $fmb;

    $self->fmb($fmb);

    my $contract_params = shortcode_to_parameters($fmb->{short_code}, $self->client->currency);
    my $limit_order = BOM::Transaction::extract_limit_orders($fmb);
    $contract_params->{limit_order} = $limit_order if %$limit_order;
    $contract_params->{is_sold} = $fmb->{is_sold};

    return produce_contract($contract_params);
}

sub _validate_update_parameter {
    my $self = shift;

    if (ref $self->update_params ne 'HASH') {
        return {
            code              => 'InvalidUpdateArgument',
            message_to_client => localize('Update only accepts hash reference as input parameter.'),
        };
    }

    my ($order_type, $order_value) = %{$self->update_params};

    unless (looks_like_number($order_value) or $order_value eq 'null') {
        return {
            code              => 'InvalidUpdateValue',
            message_to_client => localize('Update value accepts number or null string'),
        };
    }

    my $contract = $self->contract;

    unless ($contract) {
        return {
            code              => 'ContractNotFound',
            message_to_client => localize('Contract not found for contract id: [_1].', $self->contract_id),
        };
    }

    # Contract can be closed if any of the limit orders is breached.
    if ($contract->is_sold) {
        return {
            code              => 'ContractIsSold',
            message_to_client => localize('Contract has expired.'),
        };
    }

    unless (@{$contract->category->allowed_update}) {
        return {
            code              => 'UpdateNotAllowed',
            message_to_client => localize('Update is not allowed for this contract.'),
        };
    }

    unless (grep { $self->update_params->{$_} } @{$contract->category->allowed_update}) {
        return {
            code => 'UpdateNotAllowed',
            message_to_client =>
                localize('Update is not allowed for this contract. Allowed updates [_1]', join(',', @{$contract->category->allowed_update})),
        };
    }

    # when it reaches this stage, if it is a cancel operation, let it through
    return undef if $order_value eq 'null';

    my $new_order = $contract->new_order({$order_type => $order_value});
    unless ($new_order->is_valid($contract->underlying->spot_tick->quote)) {
        return {
            code              => 'InvalidContractUpdate',
            message_to_client => localize(
                ref $new_order->validation_error->{message_to_client} eq 'ARRAY'
                ? @{$new_order->validation_error->{message_to_client}}
                : $new_order->validation_error->{message_to_client}
            ),
        };
    }

    $self->new_order($new_order);

    return undef;
}

sub is_valid_to_update {
    my $self = shift;

    my $error = $self->_validate_update_parameter();

    if ($error) {
        $self->validation_error($error);
        return 0;
    }

    return 1;
}

sub update {
    my ($self) = @_;

    my ($order_type, $order_value) = %{$self->update_params};

    my $res_table =
        BOM::Database::Helper::FinancialMarketBet->new(db => BOM::Database::ClientDB->new({broker_code => $self->client->broker_code})->db)
        ->update_multiplier_contract({
            contract_id  => $self->contract_id,
            order_type   => $order_type,
            order_value  => $order_value,
            add_to_audit => $self->_order_exists($order_type),
        })->{$self->contract_id};

    return undef unless $res_table;

    my $res = $self->build_contract_update_response($order_type, $order_value);
    $res->{updated_queue} = $self->_requeue_transaction($order_type);

    return $res;
}

sub build_contract_update_response {
    my $self = shift;

    my $contract = $self->contract;
    # we will need to resubscribe for the new proposal open contract when the contract
    # parameters changed, if subscription is turned on. That's why we need contract_details.
    my %common_details = (
        account_id      => $self->client->account->id,
        shortcode       => $self->fmb->{short_code},
        contract_id     => $self->fmb->{id},
        currency        => $self->client->currency,
        buy_price       => $self->fmb->{buy_price},
        sell_price      => $self->fmb->{sell_price},
        sell_time       => $self->fmb->{sell_time},
        purchase_time   => Date::Utility->new($self->fmb->{purchase_time})->epoch,
        is_sold         => $self->fmb->{is_sold},
        transaction_ids => {buy => $self->fmb->{buy_transaction_id}},
        longcode        => localize($contract->longcode),
    );

    my $display = $contract->available_orders_for_display($self->new_order);
    $display->{$_}->{display_name} = localize($display->{$_}->{display_name}) for keys %$display;

    return {
        take_profit => $display->{take_profit} // {},
        stop_loss   => $display->{stop_loss}   // {},
        contract_details => {
            %common_details,
            limit_order => $self->contract->available_orders($self->new_order),
        },
        old_contract_details => {
            %common_details,
            limit_order => $self->contract->available_orders,
        },
    };
}

has new_order => (
    is       => 'rw',
    init_arg => undef,
);

### PRIVATE ###

sub _requeue_transaction {
    my ($self, $order_type) = @_;

    my $fmb      = $self->fmb;
    my $contract = $self->contract;

    my $expiry_queue_params = {
        purchase_price        => $fmb->{buy_price},
        transaction_reference => $fmb->{buy_transaction_id},
        contract_id           => $fmb->{id},
        symbol                => $fmb->{underlying_symbol},
        in_currency           => $self->client->currency,
        held_by               => $self->client->loginid,
    };

    my $which_side = $order_type . '_side';
    my $key = $contract->$which_side eq 'lower' ? 'down_level' : 'up_level';

    $expiry_queue_params->{$key} = $contract->$order_type->barrier_value if $contract->$order_type;
    my $out = dequeue_open_contract($expiry_queue_params) // 0;
    delete $expiry_queue_params->{$key};
    $expiry_queue_params->{$key} = $self->new_order->barrier_value if $self->new_order;
    my $in = enqueue_open_contract($expiry_queue_params) // 0;

    return {
        out => $out,
        in  => $in,
    };
}

sub _order_exists {
    my ($self, $order_type) = @_;

    # The following scenarios define the status of the order:
    # 1. Both order amount and order date are defined: active order.
    # 2. Only the order date is defined: order cancelled.
    # 3. Both order amount and order date are undefined: no order is placed throughout the life time of the contract.

    my $fmb = $self->fmb;
    return 1 if $fmb and defined $fmb->{$order_type . '_order_date'};
    return 0;
}

1;
