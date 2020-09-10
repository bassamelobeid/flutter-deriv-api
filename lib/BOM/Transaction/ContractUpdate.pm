package BOM::Transaction::ContractUpdate;

use Moo;

use BOM::Platform::Context qw(localize);
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::Helper::FinancialMarketBet;

use BOM::Config::Runtime;
use BOM::Config::Redis;
use Date::Utility;
use Scalar::Util qw(looks_like_number);
use BOM::Transaction::Utility;
use Finance::Contract::Longcode qw(shortcode_to_parameters);
use BOM::Product::ContractFactory qw(produce_contract);
use ExpiryQueue;

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

has update_params => (is => 'ro');

has [qw(fmb validation_error)] => (
    is       => 'rw',
    init_arg => undef,
    default  => undef,
);

sub BUILD {
    my $self = shift;

    my $contract = $self->_build_contract();

    unless ($contract) {
        $self->validation_error({
            code              => 'ContractNotFound',
            message_to_client => localize('This contract was not found among your open positions.'),
        });
    }

    $self->contract($contract);

    return;
}

has contract => (
    is => 'rw',
);

sub _build_contract {
    my $self = shift;

    return undef unless $self->client->default_account;

    my $fmb_dm = $self->_fmb_datamapper;
    # fmb reference with buy_transantion transaction ids (buy or buy and sell)
    my $fmb = $fmb_dm->get_contract_by_account_id_contract_id($self->client->default_account->id, $self->contract_id)->[0];

    return undef unless $fmb;

    $self->fmb($fmb);

    my $contract_params = shortcode_to_parameters($fmb->{short_code}, $self->client->currency);
    my $limit_order     = BOM::Transaction::Utility::extract_limit_orders($fmb);
    $contract_params->{limit_order} = $limit_order if %$limit_order;

    $contract_params->{is_sold}    = $fmb->{is_sold};
    $contract_params->{sell_time}  = $fmb->{sell_time} if $fmb->{sell_time};
    $contract_params->{sell_price} = $fmb->{sell_price} if $fmb->{sell_price};

    return produce_contract($contract_params);
}

has allowed_update => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_allowed_update',
);

sub _build_allowed_update {
    my $self = shift;

    return {map { $_ => 1 } @{$self->contract->category->allowed_update}};
}

sub _validate_update_parameter {
    my $self = shift;

    my $contract = $self->contract;

    # update is not allowed when suspend trade is activated.
    my $offerings = $self->client->landing_company->basic_offerings(BOM::Config::Runtime->instance->get_offerings_config('sell'));
    if ($offerings->is_disabled($self->contract->metadata('sell'))) {
        return {
            code              => 'Update is not available',
            message_to_client => localize('Update of stop loss and take profit is not available at the moment.'),
        };
    }

    # Contract can be closed if any of the limit orders is breached.
    # if contract is sold, don't proceed.
    if ($contract->is_sold) {
        return {
            code              => 'ContractIsSold',
            message_to_client => localize('Contract has expired.'),
        };
    }

    # If no update is allowed for this contract, don't proceed
    unless (keys %{$self->allowed_update}) {
        return {
            code => 'UpdateNotAllowed',
            message_to_client =>
                localize('This contract cannot be updated once you\'ve made your purchase. This feature is not available for this contract type.'),
        };
    }

    if (ref $self->update_params ne 'HASH') {
        return {
            code              => 'InvalidUpdateArgument',
            message_to_client => localize('Only a hash reference input is accepted.'),
        };
    }

    my $error;
    foreach my $order_name (keys %{$self->update_params}) {
        my $order_value = $self->update_params->{$order_name}
            // 'null';    # when $order_value is set to 'null', the limit order will be cancelled if exists

        unless (looks_like_number($order_value) or $order_value eq 'null') {
            $error = {
                code              => 'InvalidUpdateValue',
                message_to_client => localize('Please enter a number or a null value.'),
            };
            last;
        }
        unless ($self->allowed_update->{$order_name}) {
            $error = {
                code => 'UpdateNotAllowed',
                message_to_client =>
                    localize('Only updates to these parameters are allowed [_1].', join(',', @{$contract->category->allowed_update})),
            };
            last;
        }

        # when it reaches this stage, if it is a cancel operation, let it through
        if ($order_value eq 'null') {
            # If there's an existing order, this is a cancellation.
            # Else, just ignore.
            if ($contract->$order_name) {
                my $new_order = $contract->new_order({$order_name => undef});
                $self->$order_name($new_order);
                $self->requeue_stop_out(1) if $order_name eq 'stop_loss';
            }
            next;
        }

        # if it is an update, we need to check for the validity of the update
        my $new_order = $contract->new_order({$order_name => $order_value});

        # We need to limit the number of updates per second.
        # Currently, we only allow one update per second which I think is reason.
        if ($contract->$order_name and $new_order->order_date->epoch <= $contract->$order_name->order_date->epoch) {
            $error = {
                code              => 'TooFrequentUpdate',
                message_to_client => localize('Only one update per second is allowed.'),
            };
            last;
        }

        # stop loss cannot be added while deal cancellation is active
        if ($contract->is_valid_to_cancel) {
            if ($order_name eq 'stop_loss') {
                $error = {
                    code              => 'UpdateStopLossNotAllowed',
                    message_to_client => localize('You may update your stop loss amount after deal cancellation has expired.'),
                };
            } elsif ($order_name eq 'take_profit') {
                $error = {
                    code              => 'UpdateTakeProfitNotAllowed',
                    message_to_client => localize('You may update your take profit amount after deal cancellation has expired.'),
                };
            }
            last;
        }

        # is the new limit order valid?
        unless ($new_order->is_valid($contract->total_pnl, $self->client->currency)) {
            $error = {
                code              => 'InvalidContractUpdate',
                message_to_client => localize(
                    ref $new_order->validation_error->{message_to_client} eq 'ARRAY'
                    ? @{$new_order->validation_error->{message_to_client}}
                    : $new_order->validation_error->{message_to_client}
                ),
            };
            last;
        }

        $self->$order_name($new_order);
    }

    return $error if $error;

    return undef;
}

sub is_valid_to_update {
    my $self = shift;

    return 0 if $self->validation_error;

    my $error = $self->_validate_update_parameter();

    if ($error) {
        $self->validation_error($error);
        return 0;
    }

    return 1;
}

sub update {
    my ($self) = @_;

    my $update_args = {contract_id => $self->contract_id};
    foreach my $order_name (keys %{$self->update_params}) {
        if (my $order = $self->$order_name) {
            # $order->order_amount will be undef for cancel operation so we pass
            # in 0 to database function to perform cancellation
            $update_args->{$order_name} = $order->order_amount // 0;
        }
    }

    my $res_table =
        BOM::Database::Helper::FinancialMarketBet->new(db => BOM::Database::ClientDB->new({broker_code => $self->client->broker_code})->db)
        ->update_multiplier_contract($update_args)->{$self->contract_id};

    return undef unless $res_table;

    my $res = $self->build_contract_update_response();
    $res->{updated_queue} = $self->_requeue_transaction();

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

    my %new_orders = map { $_ => $self->$_ } grep { $self->$_ } keys %{$self->update_params};
    my $display    = $contract->available_orders_for_display(\%new_orders);
    $display->{$_}->{display_name} = localize($display->{$_}->{display_name}) for keys %$display;

    return {
        take_profit => $display->{take_profit} // {},
        stop_loss   => $display->{stop_loss}   // {},
        contract_details => {
            %common_details,
            limit_order => $self->contract->available_orders(\%new_orders),
        }};
}

has [qw(take_profit stop_loss)] => (
    is       => 'rw',
    init_arg => undef,
);

has requeue_stop_out => (
    is        => 'rw',
    default   => 0,
    init_args => undef,
);

### PRIVATE ###

sub _requeue_transaction {
    my $self = shift;

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

    my $redis   = BOM::Config::Redis::redis_expiryq_write;
    my $expiryq = ExpiryQueue->new(redis => $redis);
    my ($in, $out);
    foreach my $order_type (keys %{$self->update_params}) {
        my $which_side = $order_type . '_side';
        my $key        = $contract->$which_side eq 'lower' ? 'down_level' : 'up_level';

        $expiry_queue_params->{$key} = $contract->$order_type->barrier_value if $contract->$order_type;
        $out = $expiryq->dequeue_open_contract($expiry_queue_params) // 0;
        delete $expiry_queue_params->{$key};
        $expiry_queue_params->{$key} = $self->$order_type->barrier_value if $self->$order_type;
        $in = $expiryq->enqueue_open_contract($expiry_queue_params) // 0;
    }

    # when stop loss is cancelled, we need to requeue stop out
    if ($self->requeue_stop_out) {
        my $key = $contract->stop_out_side eq 'lower' ? 'down_level' : 'up_level';
        $expiry_queue_params->{$key} = $contract->stop_out->barrier_value;
        $expiryq->enqueue_open_contract($expiry_queue_params);
    }

    return {
        out => $out,
        in  => $in,
    };
}

has _fmb_datamapper => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_fmb_datamapper',
);

sub _build_fmb_datamapper {
    my $self = shift;

    return BOM::Database::DataMapper::FinancialMarketBet->new(
        broker_code => $self->client->broker_code,
        operation   => 'replica',
    );
}

1;
