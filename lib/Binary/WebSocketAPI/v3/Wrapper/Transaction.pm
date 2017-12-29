
package Binary::WebSocketAPI::v3::Wrapper::Transaction;

use strict;
use warnings;

use List::Util qw(first);

use Binary::WebSocketAPI::v3::Wrapper::System;
use Binary::WebSocketAPI::v3::Wrapper::Streamer;

sub buy_store_last_contract_id {
    my ($c, $api_response) = @_;

    my $last_contracts = $c->stash('last_contracts') // {};
    # see cleanup at Binary::WebSocketAPI::Hooks::cleanup_stored_contract_ids
    ### For usual buy
    my @contracts_ids = ($api_response->{contract_id});
    ### For buy_contract_for_multiple_accounts
    @contracts_ids = grep { $_ } map { $_->{contract_id} } @{$api_response->{result}}
        if $api_response->{result} && ref $api_response->{result} eq 'ARRAY';

    my $now = time;
    @{$last_contracts}{@contracts_ids} = ($now) x @contracts_ids;

    $c->stash(last_contracts => $last_contracts);
    return;
}

sub buy_get_contract_params {
    my ($c, $req_storage) = @_;
    my $args = $req_storage->{args};
    # Take parameters from args if $args->{parameters} is defined instead ot taking it from proposal
    if ($args->{parameters}) {
        $req_storage->{call_params}->{contract_parameters} = $args->{parameters};
        $req_storage->{call_params}->{contract_parameters}->{app_markup_percentage} = $c->stash('app_markup_percentage');
        return;
    }
    if (my $proposal_id = $args->{buy} // $args->{buy_contract_for_multiple_accounts}) {
        my $ch = $c->stash('pricing_channel');
        if ($ch and $ch = $ch->{uuid} and $ch = $ch->{$proposal_id}) {
            $req_storage->{call_params}->{payout}                                       = $ch->{cache}->{payout};
            $req_storage->{call_params}->{contract_parameters}                          = $ch->{args};
            $req_storage->{call_params}->{contract_parameters}->{app_markup_percentage} = $c->stash('app_markup_percentage');
            Binary::WebSocketAPI::v3::Wrapper::System::_forget_pricing_subscription($c, $proposal_id);
            return;
        }
    }
    return $c->new_error(($args->{buy_contract_for_multiple_accounts} ? 'buy_contract_for_multiple_accounts' : 'buy'),
        'InvalidContractProposal', $c->l("Unknown contract proposal"));
}

sub transaction {
    my ($c, $req_storage) = @_;

    my $id;
    my $args       = $req_storage->{args};
    my $account_id = $c->stash('account_id');
    if ($account_id) {
        if (    exists $args->{subscribe}
            and $args->{subscribe} eq '1'
            and (not $id = Binary::WebSocketAPI::v3::Wrapper::Streamer::transaction_channel($c, 'subscribe', $account_id, 'transaction', $args)))
        {
            return $c->new_error('transaction', 'AlreadySubscribed', $c->l('You are already subscribed to transaction updates.'));
        }
    }

    return {
        msg_type => 'transaction',
        transaction => {$id ? (id => $id) : ()}};
}

1;
