
package BOM::WebSocketAPI::v3::Wrapper::Transaction;

use strict;
use warnings;

use JSON;
use List::Util qw(first);

use BOM::WebSocketAPI::v3::Wrapper::System;
use BOM::WebSocketAPI::v3::Wrapper::Streamer;

sub buy_get_contract_params {
    my ($c, $args, $params) = @_;

    # 1. Take parameters from args if $args->{parameters} is defined instead ot taking it from proposal
    # 2. Calling forget_buy_proposal instead of forget_one as we need args for contract proposal
    if ($args->{parameters}) {
        $params->{call_params}->{contract_parameters} = $args->{parameters};
        return;
    }

    if (my $proposal_id = $args->{buy} // $args->{buy_contract_for_multiple_accounts}) {
        if (my $p = BOM::WebSocketAPI::v3::Wrapper::System::forget_buy_proposal($c, $proposal_id)) {
            $params->{call_params}->{contract_parameters} = $p;
            return;
        }

        if ($c->stash('pricing_channel') and $c->stash('pricing_channel')->{uuid} and $c->stash('pricing_channel')->{uuid}->{$proposal_id}) {
            $params->{call_params}->{contract_parameters} = $c->stash('pricing_channel')->{uuid}->{$proposal_id}->{args};
            BOM::WebSocketAPI::v3::Wrapper::System::_forget_all_pricing_subscriptions($c, $proposal_id);
            return;
        }
    }

    return $c->new_error(($args->{buy_contract_for_multiple_accounts} ? 'buy_contract_for_multiple_accounts' : 'buy'),
        'InvalidContractProposal', $c->l("Unknown contract proposal"));
}

sub transaction {
    my ($c, $args) = @_;

    my $id;
    my $account_id = $c->stash('account_id');
    if ($account_id) {
        if (    exists $args->{subscribe}
            and $args->{subscribe} eq '1'
            and (not $id = BOM::WebSocketAPI::v3::Wrapper::Streamer::_transaction_channel($c, 'subscribe', $account_id, 'transaction', $args)))
        {
            return $c->new_error('transaction', 'AlreadySubscribed', $c->l('You are already subscribed to transaction updates.'));
        }
    }

    return {
        msg_type => 'transaction',
        transaction => {$id ? (id => $id) : ()}};
}

1;
