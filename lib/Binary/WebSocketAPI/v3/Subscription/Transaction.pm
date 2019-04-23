package Binary::WebSocketAPI::v3::Subscription::Transaction;

use strict;
use warnings;

use Binary::WebSocketAPI::v3::Wrapper::Streamer;
use Format::Util::Numbers qw(formatnumber);
use Future;
use Log::Any qw($log);
use Moo;
with 'Binary::WebSocketAPI::v3::SubscriptionRole';

use namespace::clean;

=head1 NAME

Binary::WebSocketAPI::v3::Subscription::Transaction - The class that handle transaction channels

=head1 DESCRIPTION

This module deals with the transaction channel subscriptions. We can subscribe one channel as many times as we want.
L<Binary::WebSocketAPI::v3::SubscriptionManager> will subscribe that channel on redis server only once and this module will register
information that will be fetched when the message arrive. So to avoid duplicate subscription, we can store
the worker in the stash with the unique key.

Please refer to L<Binary::WebSocketAPI::v3::SubscriptionRole>

=head1 SYNOPSIS

    my $worker = Binary::WebSocketAPI::v3::Subscription::Transaction->new(
        c           => $c,
        account_id  => $account_id,
        type        => $type,
        contract_id => $contract_id,
        args        => $args,
        uuid        => $uuid,
    );

    $worker->unsubscribe;
    undef $worker; # Destroying the object will also call unusbscirbe method

=cut

=head1 ATTRIBUTES

=head2 type

The type of subscription, like 'poc', 'balance', 'transaction'

=cut

has type => (
    is       => 'ro',
    required => 1,
);

=head2 contract_id

=cut

has contract_id => (
    is       => 'ro',
    required => 1,

);

=head2 account_id

=cut

has account_id => (
    is       => 'ro',
    required => 1,
);


sub subscription_manager {
    return Binary::WebSocketAPI::v3::SubscriptionManager->shared_redis_manager();
}

=head2 channel

The channel name

=cut

sub channel { return 'TXNUPDATE::transaction_' . shift->account_id }

=head2 handle_error

=cut

sub handle_error {
    my ($self, $err, $message) = @_;
    if ($err eq 'TokenDeleted') {
        delete $self->c->stash->{'transaction_channel'};
        return;
    }
    $log->warnf("error happened in class %s channel %s message %s: $err", $self->class, $self->channel, $message);
    return;
}

=head2 handle_message

The function that process the message.

=cut

sub handle_message {
    my ($self, $message) = @_;

    my $c = $self->c;

    if (!$c->stash('account_id')) {
        delete $c->stash->{'transaction_channel'};
        return;
    }

    Future->call(
        sub {
            my $type = $self->type;
            ### new proposal_open_contract stream after buy
            ### we have to do it here. we have not longcode in payout.
            ### we'll start new bid stream if we have proposal_open_contract subscription and have bought a new contract

            return $self->_create_poc_stream($message)
                if ($type eq 'poc' && $message->{action_type} eq 'buy');

            $self->_update_balance($message)
                if $type eq 'balance';

            $self->_update_transaction($message)
                if $type eq 'transaction';

            $self->_close_proposal_open_contract_stream($message)
                if $type =~ /\w{8}-\w{4}-\w{4}-\w{4}-\w{12}/ && $message->{action_type} eq 'sell';

            return Future->done;
        }
        )->on_fail(
        sub {
            warn "ERROR - @_";
        })->retain;
    return;
}

=head2 _close_proposal_open_contract_stream

close proposal_open_contract stream if the contract sold

=cut

sub _close_proposal_open_contract_stream {
    my ($self, $payload) = @_;
    my $c           = $self->c;
    my $contract_id = $self->contract_id;
    my $uuid        = $self->type;

    if (    exists $payload->{financial_market_bet_id}
        and $contract_id
        and $payload->{financial_market_bet_id} eq $contract_id)
    {
        $payload->{sell_time} = Date::Utility->new($payload->{sell_time})->epoch;
        $payload->{uuid}      = $uuid;

        Binary::WebSocketAPI::v3::Wrapper::Pricer::send_proposal_open_contract_last_time($c, $payload, $contract_id, $self->request_storage);
    }
    return;
}

=head2 _update_transaction

send transaction updating message to frontend if the message is about transaction

=cut

sub _update_transaction {
    my ($self, $payload) = @_;
    my $c    = $self->c;
    my $args = $self->args;
    my $id   = $self->uuid;

    my $details = {
        msg_type => 'transaction',
        $args ? (echo_req => $args) : (),
        transaction => {
            ($id ? (id => $id) : ()),
            balance        => formatnumber('amount', $payload->{currency_code}, $payload->{balance_after}),
            action         => $payload->{action_type},
            amount         => $payload->{amount},
            transaction_id => $payload->{id},
            longcode       => $payload->{payment_remark},
            contract_id    => $payload->{financial_market_bet_id},
            ($payload->{currency_code} ? (currency => $payload->{currency_code}) : ()),
        },
        $id ? (subscription => {id => $id}) : (),
    };

    if (($payload->{referrer_type} // '') ne 'financial_market_bet') {
        $details->{transaction}->{transaction_time} = Date::Utility->new($payload->{payment_time})->epoch;
        $c->send({json => $details}, $self->request_storage);
        return;
    }

    $details->{transaction}->{transaction_time} = Date::Utility->new($payload->{sell_time} || $payload->{purchase_time})->epoch;

    $c->call_rpc({
            args        => $args,
            msg_type    => 'transaction',
            method      => 'get_contract_details',
            call_params => {
                token           => $c->stash('token'),
                short_code      => $payload->{short_code},
                currency        => $payload->{currency_code},
                language        => $c->stash('language'),
                landing_company => $c->landing_company_name,
            },
            rpc_response_cb => sub {
                my ($c, $rpc_response) = @_;

                if (exists $rpc_response->{error}) {
                    Binary::WebSocketAPI::v3::Wrapper::System::forget_one($c, $id) if $id;
                    return $c->new_error('transaction', $rpc_response->{error}->{code}, $rpc_response->{error}->{message_to_client});
                } else {
                    $details->{transaction}->{purchase_time} = Date::Utility->new($payload->{purchase_time})->epoch
                        if ($payload->{action_type} eq 'sell');
                    $details->{transaction}->{longcode}     = $rpc_response->{longcode};
                    $details->{transaction}->{symbol}       = $rpc_response->{symbol};
                    $details->{transaction}->{display_name} = $rpc_response->{display_name};
                    $details->{transaction}->{date_expiry}  = $rpc_response->{date_expiry};
                    $details->{transaction}->{barrier}      = $rpc_response->{barrier} if exists $rpc_response->{barrier};
                    $details->{transaction}->{high_barrier} = $rpc_response->{high_barrier} if $rpc_response->{high_barrier};
                    $details->{transaction}->{low_barrier}  = $rpc_response->{low_barrier} if $rpc_response->{low_barrier};

                    return $details;
                }
            },
        });
    return;
}

#send balance updating message to frontend if the message is about balance
sub _update_balance {
    my ($self, $payload) = @_;
    my $c    = $self->c;
    my $args = $self->args;
    my $id   = $self->uuid;

    my $details = {
        msg_type => 'balance',
        $args ? (echo_req => $args) : (),
        balance => {
            ($id ? (id => $id) : ()),
            loginid  => $c->stash('loginid'),
            currency => $c->stash('currency'),
            balance  => formatnumber('amount', $c->stash('currency'), $payload->{balance_after}),
        },
        $id ? (subscription => {id => $id}) : (),
    };

    $c->send({json => $details}, $self->request_storage) if $c->tx;
    return;
}

=head2 _create_poc_stream

create proposal_open_contract stream if the message shows that a new contract bought.

=cut

# POC means proposal_open_contract
sub _create_poc_stream {
    my $self    = shift;
    my $payload = shift;

    my $c        = $self->c;
    my $poc_args = $c->stash('proposal_open_contracts_subscribed');

    return Future->done unless $poc_args && $payload->{financial_market_bet_id};

    return $c->longcode($payload->{short_code}, $payload->{currency_code})->then(
        sub {
            my ($longcode) = @_;
            $payload->{longcode} = $longcode
                or warn "Had no longcode for $payload->{short_code} currency $payload->{currency_code} language " . $c->stash('language');
            return Future->done;
        },
        sub {
            my ($error, $category, @details) = @_;
            warn "Longcode failure, falling back to placeholder text - $error ($category: @details)\n";
            $payload->{longcode} = $c->l('Could not retrieve contract details');
            return Future->done;
        }
        )->then(
        sub {
            my $uuid = Binary::WebSocketAPI::v3::Wrapper::Pricer::pricing_channel_for_bid(
                $c,
                $poc_args,
                {
                    shortcode   => $payload->{short_code},
                    currency    => $payload->{currency_code},
                    is_sold     => $payload->{sell_time} ? 1 : 0,
                    contract_id => $payload->{financial_market_bet_id},
                    buy_price   => $payload->{purchase_price},
                    account_id  => $payload->{account_id},
                    longcode => $payload->{longcode} || $payload->{payment_remark},
                    transaction_ids => {buy => $payload->{id}},
                    purchase_time   => Date::Utility->new($payload->{purchase_time})->epoch,
                    sell_price      => undef,
                    sell_time       => undef,
                });
            $self->request_storage->{args} = $poc_args;
            # subscribe to transaction channel as when contract is manually sold we need to cancel streaming
            Binary::WebSocketAPI::v3::Wrapper::Streamer::transaction_channel($c, 'subscribe', $payload->{account_id},
                $uuid, $self->request_storage, $payload->{financial_market_bet_id})
                if $uuid;
            return Future->done;
        });
}

1;

