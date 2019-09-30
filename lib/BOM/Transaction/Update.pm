package BOM::Transaction::ContractUpdate;

use strict;
use warnings;

use BOM::Platform::Context qw(localize);
use BOM::Database::DataMapper::FinancialMarketBet;

use Finance::Contract::Category;
use Finance::Contract::Longcode qw(shortcode_to_parameters);

=head1 NAME

BOM::Transaction::ContractUpdate - contains methods to update a contract

=cut

sub update {
    my $args = shift;

    my $dm = BOM::Database::DataMapper::FinancialMarketBet->new(
        broker_code => $args->{client}->broker_code,
        operation   => 'write',
    );

    # We could probably just have an update function, but we
    # want verify if this contract allows update.
    my $fmbs = $dm->get_fmb_by_id([$args->{contract_id}]);

    unless ($fmbs) {
        return {
            error => {
                code              => 'ContractNotFound',
                message_to_client => localize('Conntract not found for contract_id: [_1].', $args->{contract_id}),
            }};
    }

    my $fmb = $fmbs->[0]->financial_market_bet_record;
    # Didn't want to go through the whole produce_contract method since we only need to get the category,
    # But, even then it feels like a hassle.
    my $contract_params = shortcode_to_parameters($fmb->{short_code}, $args->{client}->currency);
    my $config          = Finance::Contract::Category::get_all_contract_types()->{$contract_params->{bet_type}};
    my $category        = Finance::Contract::Category->new($config->{category});

    my %allowed = map { $_ => 1 } @{$category->allowed_update};
    unless (%allowed) {
        return {
            error => {
                code              => 'UpdateNotAllowed',
                message_to_client => localize('Update is not allowed for this contract.'),
            }};
    }

    # currently only supports take profit, so hard-coding it.
    my $order_type    = 'take_profit';
    my $update_params = $args->{params}->{$order_type};

    unless ($update_params) {
        return {
            error => {
                code              => 'UpdateNotAllowed',
                message_to_client => localize('Update is not allowed for this contract. Allowed updates [_1]', join(',', keys %allowed)),
            }};
    }

    if ($update_params->{operation} eq 'update' and not defined $update_params->{value}) {
        return {
            error => {
                code              => 'ValueNotDefined',
                message_to_client => localize('Value is required for update operation.'),
            }};
    }

    my $status;
    if ($update_params->{operation} eq 'cancel' or $update_params->{operation} eq 'update') {
        my $method = $order_type . '_order_amount';
        my $add_to_audit = defined $fmb->multiplier->$method ? 1 : 0;
        $status = $dm->update_take_profit($args->{contract_id}, $update_params, $add_to_audit);
    } else {
        return {
            error => {
                code              => 'UnknownUpdateOperation',
                message_to_client => localize('This operation is not supported.'),
            }};
    }

    return $status;
}

1;
