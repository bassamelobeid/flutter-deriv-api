
package BOM::WebSocketAPI::v3::Wrapper::Transaction;

use strict;
use warnings;

use JSON;
use List::Util qw(first);

use BOM::WebSocketAPI::Websocket_v3;
use BOM::WebSocketAPI::v3::Wrapper::System;
use BOM::WebSocketAPI::v3::Wrapper::Streamer;

sub buy_get_contract_params {
    my ($c, $args, $params) = @_;

    # 1. Take parameters from args if $args->{parameters} is defined instead ot taking it from proposal
    # 2. Calling forget_buy_proposal instead of forget_one as we need args for contract proposal
    $params->{call_params}->{contract_parameters} =
           $args->{parameters}
        || BOM::WebSocketAPI::v3::Wrapper::System::forget_buy_proposal($c, $args->{buy})
        || return $c->new_error('buy', 'InvalidContractProposal', $c->l("Unknown contract proposal"));
    return;
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
        transaction => {$id ? (id => $id) : ''}};
}

1;
