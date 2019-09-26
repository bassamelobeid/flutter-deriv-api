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

    my $update_params = $args->{params};
    # technically, we should be allowing multiple updates,
    # but I am not sure how the user interface will be. So, do update one at a time
    my ($update) = keys %$update_params;

    unless ($allowed{$update}) {
        return {
            error => {
                code              => 'UpdateNotAllowed',
                message_to_client => localize('Update is not allowed for this contract. Allowed updates [$_]', join(',', keys %allowed)),
            }};
    }

    my $status;
    if ($update_params->{$update}->{operation} eq 'cancel') {
        $status = $dm->delete_order($args->{contract_id}, $update);
    } elsif ($update_params->{$update}->{operation} eq 'update') {
        $status = $dm->update_order($args->{contract_id}, $update);
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
