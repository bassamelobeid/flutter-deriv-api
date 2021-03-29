package Binary::WebSocketAPI::v3::Subscription::Transaction;
use strict;
use warnings;
use feature qw(state);
no indirect;

use Binary::WebSocketAPI::v3::Wrapper::Transaction;
use Binary::WebSocketAPI::v3::Wrapper::Pricer;
use Format::Util::Numbers qw(formatnumber);
use Future;
use Log::Any qw($log);
use Moo;
use Carp qw(croak);
use List::Util qw(any);
use Scalar::Util qw(blessed);
with 'Binary::WebSocketAPI::v3::Subscription';

use namespace::clean;

=head1 NAME

Binary::WebSocketAPI::v3::Subscription::Transaction - The class that handle transaction channels

=head1 DESCRIPTION

This module deals with the transaction channel subscriptions. We can subscribe one channel as many times as we want.
L<Binary::WebSocketAPI::v3::SubscriptionManager> will subscribe that channel on redis server only once and this module will register
information that will be fetched when the message arrive. So to avoid duplicate subscription, we can store
the worker in the stash with the unique key.

Please refer to L<Binary::WebSocketAPI::v3::Subscription>

=head1 SYNOPSIS

    my $worker = Binary::WebSocketAPI::v3::Subscription::Transaction->new(
        c           => $c,
        account_id  => $account_id,
        type        => $type,
        contract_id => $contract_id,
        args        => $args,
    );

    $worker->unsubscribe;
    undef $worker; # Destroying the object will also call unusbscirbe method

=cut

=head1 ATTRIBUTES

=head2 type

The type of subscription, like 'buy', 'balance', 'transaction', 'sell'

=cut

has type => (
    is       => 'ro',
    required => 1,
    isa      => sub {
        state $allowed_types = {map { $_ => 1 } qw(buy balance balance_all transaction sell)};
        die "type can only be buy, balance, transaction, sell" unless $allowed_types->{$_[0]};
    });

=head2 contract_id

=cut

has contract_id => (
    is       => 'ro',
    required => 0,

);

=head2 account_id

=cut

has account_id => (
    is       => 'ro',
    required => 1,
);

=head2 loginid

used for balance type

=cut

has loginid => (
    is => 'ro',
);

=head2 currency

used for balance type

=cut

has currency => (
    is => 'ro',
);

=head2 balance_all_proxy

The balance_all object that used to process message and emit results.

=cut

has balance_all_proxy => (
    is  => 'ro',
    isa => sub {
        die "balance_all_proxy need a Binary::WebSocketAPI::v3::Subscription::BalanceAll"
            unless blessed($_[0]) eq 'Binary::WebSocketAPI::v3::Subscription::BalanceAll';
    },
    weak_ref => 1,
);

has currency_rate_in_total_currency => (is => 'ro');

sub subscription_manager {
    return Binary::WebSocketAPI::v3::SubscriptionManager->redis_transaction_manager();
}

=head2 channel

The channel name

=cut

sub _build_channel { return 'TXNUPDATE::transaction_' . shift->account_id }

# This method is used to find a subscription. Class name + _unique_key will be a unique index of the subscription objects.
sub _unique_key {
    my $self = shift;
    if ($self->type eq 'balance') {
        my $type = $self->balance_all_proxy ? 'balanceall' : 'balance';
        return $type . ':' . $self->account_id;
    }
    return $self->type . ':' . $self->account_id;
}

=head2 handle_error

=cut

before handle_error => sub {
    my ($self, $err, $message) = @_;
    return;
};

=head2 handle_message

The function that process the message.

=cut

sub handle_message {
    my ($self, $message) = @_;

    my $c = $self->c;

    if (!$c->stash('account_id')) {
        $self->unregister_class();
        return undef;
    }

    Future->call(
        sub {
            my $type = $self->type;

            $self->_update_balance($message)
                if $type eq 'balance';

            $self->_update_transaction($message)
                if $type eq 'transaction';

            return Future->done;
        }
    )->on_fail(
        sub {
            $log->warn("ERROR - @_");
        })->retain;
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
        $c->send({json => $details});
        return;
    }

    $details->{transaction}->{transaction_time} = Date::Utility->new($payload->{sell_time} || $payload->{purchase_time})->epoch;

    # TODO remove the RPC call if you can
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
                contract_id     => $payload->{financial_market_bet_id},
            },
            rpc_response_cb => sub {
                my ($c, $rpc_response) = @_;

                if (exists $rpc_response->{error}) {
                    Binary::WebSocketAPI::v3::Subscription->unregister_by_uuid($c, $id) if $id;
                    return $c->new_error('transaction', $rpc_response->{error}->{code}, $rpc_response->{error}->{message_to_client});
                } else {
                    $details->{transaction}->{purchase_time} = Date::Utility->new($payload->{purchase_time})->epoch
                        if ($payload->{action_type} eq 'sell');
                    $details->{transaction}->{longcode}     = $rpc_response->{longcode};
                    $details->{transaction}->{symbol}       = $rpc_response->{symbol};
                    $details->{transaction}->{display_name} = $rpc_response->{display_name};
                    $details->{transaction}->{date_expiry}  = $rpc_response->{date_expiry};
                    $details->{transaction}->{barrier}      = $rpc_response->{barrier}      if exists $rpc_response->{barrier};
                    $details->{transaction}->{high_barrier} = $rpc_response->{high_barrier} if $rpc_response->{high_barrier};
                    $details->{transaction}->{low_barrier}  = $rpc_response->{low_barrier}  if $rpc_response->{low_barrier};

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

    if ($self->balance_all_proxy) {
        return $self->balance_all_proxy->update_balance($self, $payload);
    }
    my $details = {
        msg_type => 'balance',
        $args ? (echo_req => $args) : (),
        balance => {
            ($id ? (id => $id) : ()),
            loginid  => $self->loginid,
            currency => $self->currency,
            balance  => formatnumber('amount', $c->stash('currency'), $payload->{balance_after}),
        },
        $id ? (subscription => {id => $id}) : (),
    };

    $c->send({json => $details}) if $c->tx;
    return;
}

1;

