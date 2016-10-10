
package Binary::WebSocketAPI::v3::Wrapper::Transaction;

use strict;
use warnings;

use JSON;
use List::Util qw(first);

use Binary::WebSocketAPI::v3::Wrapper::System;
use Binary::WebSocketAPI::v3::Wrapper::Streamer;

sub buy_get_contract_params {
    my ($c, $req_storage) = @_;

    my $args = $req_storage->{args};
    # 1. Take parameters from args if $args->{parameters} is defined instead ot taking it from proposal
    # 2. Calling forget_buy_proposal instead of forget_one as we need args for contract proposal
    if ($args->{parameters}) {
        $req_storage->{call_params}->{contract_parameters} = $args->{parameters};
        $req_storage->{call_params}->{contract_parameters}->{app_markup_percentage} = $c->stash('app_markup_percentage');
        return;
    }
    if (my $proposal_id = $args->{buy} // $args->{buy_contract_for_multiple_accounts}) {
        if (my $p = Binary::WebSocketAPI::v3::Wrapper::System::forget_buy_proposal($c, $proposal_id)) {
            $req_storage->{call_params}->{contract_parameters} = $p;
            $req_storage->{call_params}->{contract_parameters}->{app_markup_percentage} = $c->stash('app_markup_percentage');
            return;
        }
        my $ch = $c->stash('pricing_channel');
        if ($ch and $ch = $ch->{uuid} and $ch = $ch->{$proposal_id}) {
            $req_storage->{call_params}->{contract_parameters} = $ch->{args};
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
            and (not $id = Binary::WebSocketAPI::v3::Wrapper::Streamer::_transaction_channel($c, 'subscribe', $account_id, 'transaction', $args)))
        {
            return $c->new_error('transaction', 'AlreadySubscribed', $c->l('You are already subscribed to transaction updates.'));
        }
    }

    return {
        msg_type => 'transaction',
        transaction => {$id ? (id => $id) : ()}};
}

1;
