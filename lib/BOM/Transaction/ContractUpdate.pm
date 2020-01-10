package BOM::Transaction::ContractUpdate;

use Moo;

use BOM::Platform::Context qw(localize);
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::ClientDB;
use BOM::Database::Helper::FinancialMarketBet;

use Machine::Epsilon;
use Date::Utility;
use Scalar::Util qw(looks_like_number);
use BOM::Transaction;
use Finance::Contract::Longcode qw(shortcode_to_parameters);
use BOM::Product::ContractFactory qw(produce_contract);
use ExpiryQueue qw(enqueue_open_contract dequeue_open_contract);
use List::Util qw(first);

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
    is => 'ro',
);

has request_history => (
    is      => 'ro',
    default => 0,
);

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
            message_to_client => localize('No open contract found for contract id: [_1].', $self->contract_id),
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

    my $client   = $self->client;
    my $clientdb = BOM::Database::ClientDB->new({
        client_loginid => $client->loginid,
        operation      => 'replica',
    });
    my $fmb = first { $_->{id} == $self->contract_id }
    @{$clientdb->getall_arrayref('select * from bet.get_open_bets_of_account(?,?,?)', [$client->loginid, $client->currency, 'false'])};

    return undef unless $fmb;

    $self->fmb($fmb);

    my $contract_params = shortcode_to_parameters($fmb->{short_code}, $self->client->currency);
    my $limit_order = BOM::Transaction::extract_limit_orders($fmb);
    $contract_params->{limit_order} = $limit_order if %$limit_order;
    $contract_params->{is_sold}     = $fmb->{is_sold};
    $contract_params->{sell_time}   = $fmb->{sell_time} if $fmb->{sell_time};
    $contract_params->{sell_price}  = $fmb->{sell_price} if $fmb->{sell_price};

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
                localize('This contract cannot be updated once you’ve made your purchase. This feature is not available for this contract type.'),
        };
    }

    if (not $self->has_parameters_to_update or ref $self->update_params ne 'HASH') {
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
        if ($order_name eq 'stop_loss' and $contract->is_valid_to_cancel) {
            $error = {
                code => 'UpdateStopLossNotAllowed',
                message_to_client =>
                    localize('Stop loss will be available only after deal cancellation expires. You may update your stop loss limit then.'),
            };
            last;
        }

        # is the new limit order valid?
        unless ($new_order->is_valid($contract->current_pnl)) {
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
    my $display = $contract->available_orders_for_display(\%new_orders);
    $display->{$_}->{display_name} = localize($display->{$_}->{display_name}) for keys %$display;

    return {
        take_profit => $display->{take_profit} // {},
        stop_loss   => $display->{stop_loss}   // {},
        contract_details => {
            %common_details,
            limit_order => $self->contract->available_orders(\%new_orders),
        },
        ($self->request_history ? (history => $self->get_history) : ()),
    };
}

sub has_parameters_to_update {
    my $self = shift;

    return 1 if $self->update_params;
    return 0;
}

sub get_history {
    my $self = shift;

    if ($self->validation_error) {
        return $self->validation_error;
    }

    my $fmb_dm = BOM::Database::DataMapper::FinancialMarketBet->new(
        broker_code => $self->client->broker_code,
        operation   => 'replica',
    );
    my @allowed = sort keys %{$self->allowed_update};

    my $results = $fmb_dm->get_multiplier_audit_details_by_contract_id($self->contract_id);
    my @history;
    my $prev;
    for (my $i = 0; $i <= $#$results; $i++) {
        my $current = $results->[$i];
        my @entry;
        foreach my $order_type (@allowed) {
            next unless $current->{$order_type . '_order_date'};
            my $order_amount_str = $order_type . '_order_amount';
            my $display_name = $order_type eq 'take_profit' ? localize('Take profit') : localize('Stop loss');
            my $order_amount;
            unless ($prev) {
                $order_amount = $current->{$order_amount_str} ? $current->{$order_amount_str} + 0 : 0;
            } else {
                if (defined $prev->{$order_amount_str} and defined $current->{$order_amount_str}) {
                    next if (abs($prev->{$order_amount_str} - $current->{$order_amount_str}) <= machine_epsilon());
                    $order_amount = $current->{$order_amount_str} + 0;
                } elsif (defined $prev->{$order_amount_str}) {
                    $order_amount = 0;
                } elsif (defined $current->{$order_amount_str}) {
                    $order_amount = $current->{$order_amount_str} + 0;
                }
            }

            push @entry,
                +{
                display_name => $display_name,
                order_amount => $order_amount,
                order_date   => Date::Utility->new($current->{$order_type . '_order_date'})->epoch,
                value        => $self->contract->new_order({$order_type => $order_amount})->barrier_value,
                }
                if (defined $order_amount);
        }
        $prev = $current;
        push @history, @entry;
    }

    return [reverse @history];
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

    my ($in, $out);
    foreach my $order_type (keys %{$self->update_params}) {
        my $which_side = $order_type . '_side';
        my $key = $contract->$which_side eq 'lower' ? 'down_level' : 'up_level';

        $expiry_queue_params->{$key} = $contract->$order_type->barrier_value if $contract->$order_type;
        $out = dequeue_open_contract($expiry_queue_params) // 0;
        delete $expiry_queue_params->{$key};
        $expiry_queue_params->{$key} = $self->$order_type->barrier_value if $self->$order_type;
        $in = enqueue_open_contract($expiry_queue_params) // 0;
    }

    # when stop loss is cancelled, we need to requeue stop out
    if ($self->requeue_stop_out) {
        my $key = $contract->stop_out_side eq 'lower' ? 'down_level' : 'up_level';
        $expiry_queue_params->{$key} = $contract->stop_out->barrier_value;
        enqueue_open_contract($expiry_queue_params);
    }

    return {
        out => $out,
        in  => $in,
    };
}

1;
