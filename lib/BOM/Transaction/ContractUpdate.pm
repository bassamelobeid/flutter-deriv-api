package BOM::Transaction::ContractUpdate;

use Moo;

use BOM::Platform::Context qw(localize);
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::Helper::FinancialMarketBet;

use Finance::Contract::Category;
use Finance::Contract::Longcode qw(shortcode_to_parameters);
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

has validation_error => (
    is      => 'rw',
    default => sub { {} },
);

sub is_valid_to_update {
    my $self = shift;

    my $client           = $self->client;
    my $fmb              = $self->_contract_config->{fmb};
    my $contract_details = $self->_contract_config->{contract_details};

    unless ($fmb) {
        $self->_set_validation_error(
            code              => 'ContractNotFound',
            message_to_client => localize('Conntract not found for contract_id: [_1].', $self->contract_id),
        );
        return 0;
    }

    # Contract can be closed if any of the limit orders is breached.
    if ($fmb->{is_sold}) {
        $self->_set_validation_error(
            code              => 'ContractIsSold',
            message_to_client => localize('Conntract has expired.'),
        );
        return 0;
    }

    unless (%{$contract_details->{allowed_update}}) {
        $self->_set_validation_error(
            code              => 'UpdateNotAllowed',
            message_to_client => localize('Update is not allowed for this contract.'),
        );
        return 0;
    }

    if (ref $self->update_params ne 'HASH') {
        return {
            error => {
                code              => 'InvalidUpdateArgument',
                message_to_client => localize('Update only accepts hash reference as input parameter.'),
            }};
    }

    my ($order_type, $update_params) = %{$self->update_params};

    unless ($contract_details->{allowed_update}{$order_type}) {
        $self->_set_validation_error(
            code => 'UpdateNotAllowed',
            message_to_client =>
                localize('Update is not allowed for this contract. Allowed updates [_1]', join(',', keys %{$contract_details->{allowed_update}})),
        );
        return 0;
    }

    if ($update_params->{operation} eq 'update' and not defined $update_params->{value}) {
        $self->_set_validation_error(
            code              => 'ValueNotDefined',
            message_to_client => localize('Value is required for update operation.'),
        );
        return 0;
    }

    if ($update_params->{operation} ne 'cancel' and $update_params->{operation} ne 'update') {
        $self->_set_validation_error(
            code              => 'UnknownUpdateOperation',
            message_to_client => localize('This operation is not supported. Allowed operations (update, cancel).'),
        );
        return 0;
    }

    return 1;
}

sub update {
    my ($self, $args) = @_;

    my ($order_type, $update_params) = %{$self->update_params};

    my $res =
        BOM::Database::Helper::FinancialMarketBet->new(db => BOM::Database::ClientDB->new({broker_code => $self->client->broker_code})->db)
        ->update_multiplier_contract({
            contract_id   => $self->contract_id,
            order_type    => $order_type,
            update_params => $update_params,
            add_to_audit  => $self->_order_exists($order_type),
        });

    my $queue_res = $self->_requeue_transaction($order_type, $res->{$self->contract_id});

    return {
        updated_table => $res,
        updated_queue => $queue_res,
    };
}

### PRIVATE ###

has _contract_config => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_contract_config',
);

sub _build_contract_config {
    my $self = shift;

    my $fmb_dm = BOM::Database::DataMapper::FinancialMarketBet->new(
        broker_code => $self->client->broker_code,
        operation   => 'replica',
    );

    # fmb reference with buy_transantion transaction ids (buy or buy and sell)
    my $fmb = $fmb_dm->get_contract_details_with_transaction_ids($self->contract_id)->[0];

    return {} unless $fmb;

    # Didn't want to go through the whole produce_contract method since we only need to get the category,
    # But, even then it feels like a hassle.
    my $contract_params = shortcode_to_parameters($fmb->{short_code}, $self->client->currency);
    my $contract_config = Finance::Contract::Category::get_all_contract_types()->{$contract_params->{bet_type}};
    my $category        = Finance::Contract::Category->new($contract_config->{category});
    my %allowed_update  = map { $_ => 1 } @{$category->allowed_update};

    return {
        fmb              => $fmb,
        contract_details => {%$contract_config, allowed_update => \%allowed_update},
    };
}

sub _requeue_transaction {
    my ($self, $order_type, $updated_fmb) = @_;

    my $fmb              = $self->_contract_config->{fmb};
    my $contract_details = $self->_contract_config->{contract_details};

    my $expiry_queue_params = {
        purchase_price        => $fmb->{buy_price},
        transaction_reference => $fmb->{buy_transaction_id},
        contract_id           => $fmb->{id},
        symbol                => $fmb->{underlying_symbol},
        in_currency           => $self->client->currency,
        held_by               => $self->client->loginid,
    };

    my $which_side = (
               ($contract_details->{sentiment} eq 'up'   and $order_type eq 'take_profit')
            or ($contract_details->{sentiment} eq 'down' and $order_type eq 'stop_loss')) ? 'up_level' : 'down_level';

    $expiry_queue_params->{$which_side} = $fmb->{$order_type . '_order_amount'};
    my $out = dequeue_open_contract($expiry_queue_params);
    $expiry_queue_params->{$which_side} = $updated_fmb->{$order_type . '_order_amount'};
    my $in = enqueue_open_contract($expiry_queue_params);

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

    my $fmb = $self->_contract_config->{fmb};
    return 1 if $fmb and defined $fmb->{$order_type . '_order_date'};
    return 0;
}

sub _set_validation_error {
    my ($self, %error) = @_;

    $self->validation_error(\%error);
    return;
}

1;
