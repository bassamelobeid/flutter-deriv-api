
package Binary::WebSocketAPI::v3::Wrapper::Transaction;

use strict;
use warnings;

use Binary::WebSocketAPI::v3::Wrapper::System;
use Binary::WebSocketAPI::v3::Subscription::Transaction;
use Binary::WebSocketAPI::v3::Wrapper::Pricer;

sub buy_get_single_contract {
    my ($c, $api_response, $req_storage) = @_;

    my $channel          = delete $api_response->{channel};
    my $pricer_args_keys = delete $api_response->{pricer_args_keys};
    my $contract_id      = $api_response->{contract_id};

    if ($channel) {
        my $req_id = $req_storage->{call_params}->{args}->{req_id};
        my $args   = {
            proposal_open_contract => 1,
            subscribe              => 1,
            contract_id            => $contract_id,
            $req_id ? (req_id => $req_id) : ()};
        my $subscription = Binary::WebSocketAPI::v3::Subscription::Pricer::ProposalOpenContract->new(
            c           => $c,
            channel     => $channel,
            subchannel  => 1,
            pricer_args => $pricer_args_keys,
            args        => $args,
            cache       => {});

        if (!$subscription->already_registered) {
            $subscription->register();
            $req_storage->{uuid} = $subscription->uuid();
            $subscription->subscribe();
        }
    }

    $c->stash($api_response->{stash}->%*) if $api_response->{stash};

    return undef;
}

=head2 contract_update_handler

Handles contract update handling for proposal open contract.

Deletes old pricer key and sets the new pricer key
=cut

sub contract_update_handler {
    my ($c, $api_response) = @_;

    # do not send this back
    delete $api_response->{updated_queue};

    return undef;
}

=head2 buy_set_poc_subscription_id

Sets C<proposal_open_contract> stream subscription id, after a C<buy> request is successfully processed.
At this stage, the subscription id is already injected into C<$req_storage> with a JSON key named C<uuid> by the C<success> handler.

Takes the following arguments

=over 4

=item * C<$rpc_response> - message returned by rpc call.

=item * C<$api_response> - response to be sent through websocket.

=item * C<$req_storage> - JSON message containing a B<buy> request as received through websocket.

=back

Returns a JSON message, containing B<$api_response> and subscription id.

=cut

sub buy_set_poc_subscription_id {
    my ($rpc_response, $api_response, $req_storage) = @_;
    return $api_response if $rpc_response->{error};

    my $uuid = delete $req_storage->{uuid};
    return {
        buy      => $rpc_response,
        msg_type => 'buy',
        ($uuid ? (subscription => {id => $uuid}) : ()),
    };
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
        # get subscription object Proposal or ProposalArrayItem for information
        my $subscription = Binary::WebSocketAPI::v3::Subscription->get_by_uuid($c, $proposal_id);
        if ($subscription && $subscription->does('Binary::WebSocketAPI::v3::Subscription::Pricer')) {
            $req_storage->{call_params}->{payout}                                       = $subscription->cache->{payout};
            $req_storage->{call_params}->{contract_parameters}                          = $subscription->args;
            $req_storage->{call_params}->{contract_parameters}->{app_markup_percentage} = $c->stash('app_markup_percentage');
            $subscription->unregister;
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
            and (not $id = transaction_channel($c, 'subscribe', $account_id, 'transaction', $args)))
        {
            return $c->new_error('transaction', 'AlreadySubscribed', $c->l('You are already subscribed to [_1].', 'transaction'));
        }
    }

    return {
        msg_type    => 'transaction',
        transaction => {$id ? (id => $id) : ()},
        $id ? (subscription => {(id => $id)}) : (),
    };
}

sub transaction_channel {
    my ($c, $action, $account_id, $type, $args, $contract_id) = @_;

    $contract_id //= $args->{contract_id};

    my $worker = Binary::WebSocketAPI::v3::Subscription::Transaction->new(
        c           => $c,
        account_id  => $account_id,
        type        => $type,
        contract_id => $contract_id,
        args        => $args,
    );

    my $already_registered_worker = $worker->already_registered;
    if ($action eq 'subscribe' and not $already_registered_worker) {
        my $uuid = $worker->uuid();
        $worker->subscribe;
        $worker->register;
        return $uuid;
    } elsif ($action eq 'unsubscribe' and $already_registered_worker) {
        $already_registered_worker->unregister;
    } elsif ($action eq 'subscribed?') {
        return $already_registered_worker;
    }

    return undef;
}

1;
