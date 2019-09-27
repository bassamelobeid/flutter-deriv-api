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
        operation   => 'replica',
    );

    # We could probably just have an update function, but we
    # want verify if this contract allows update.
    my $fmbs = $dm->get_fmb_by_id([$args->{contract_id}]);

    return unless $fmbs;

    # Didn't want to go through the whole produce_contract method since we only need to get the category,
    # But, even then it feels like a hassle.
    my $contract_params = shortcode_to_parameters($fmbs->[0]->{short_code}, $args->{client}->currency);
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
    my $update_params = $args->{params}->{take_profit};

    unless ($update_params) {
        return {
            error => {
                code              => 'UpdateNotAllowed',
                message_to_client => localize('Update is not allowed for this contract. Allowed updates [$_]', join(',', keys %allowed)),
            }};
    }

    if ($update_params->{operation} eq 'update' and not defined $update_params->{value}) {
        return {
            error => {
                code              => 'ValueNotDefined',
                message_to_client => localize('value is required for update operation.'),
            }};
    }

    my $status;
    if ($update_params->{operation} eq 'cancel' or $update_params->{operation} eq 'update') {
        $status = $dm->update_take_profit($args->{contract_id}, $update_params);
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
