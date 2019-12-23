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

has poc_uuid => (
    is       => 'ro',
    required => 0,
    default  => sub { '' },
    isa      => sub {
        die "poc_uuid should be a uuid string" unless $_[0] =~ /^(?:\w{8}-\w{4}-\w{4}-\w{4}-\w{12})?$/;
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

sub BUILD {
    my ($self) = @_;
    die "poc_uuid is required for type 'sell'" if $self->type eq 'sell' && !$self->poc_uuid;
    return undef;
}

# This method is used to find a subscription. Class name + _unique_key will be a unique index of the subscription objects.
sub _unique_key {
    my $self = shift;
    if ($self->type eq 'balance') {
        return $self->type . ':' . $self->account_id;
    }
    return $self->type . ':' . $self->poc_uuid;
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
            ### new proposal_open_contract stream after buy
            ### we have to do it here. we have not longcode in payout.
            ### we'll start new bid stream if we have proposal_open_contract subscription and have bought a new contract

            return $self->_create_poc_stream($message)
                if ($type eq 'buy' && $message->{action_type} eq 'buy');

            $self->_update_balance($message)
                if $type eq 'balance';

            $self->_update_transaction($message)
                if $type eq 'transaction';

            $self->_close_proposal_open_contract_stream($message)
                if $self->type eq 'sell' && $message->{action_type} eq 'sell';

            return Future->done;
        }
        )->on_fail(
        sub {
            $log->warn("ERROR - @_");
        })->retain;
    return;
}

=head2 _close_proposal_open_contract_stream

close proposal_open_contract stream if the contract sold

=cut

sub _close_proposal_open_contract_stream {
    my ($self, $payload) = @_;
    my $c           = $self->c;
    my $args        = $self->args;
    my $contract_id = $self->contract_id;
    my $uuid        = $self->poc_uuid;

    if (    exists $payload->{financial_market_bet_id}
        and $contract_id
        and $payload->{financial_market_bet_id} eq $contract_id)
    {
        $payload->{sell_time} = Date::Utility->new($payload->{sell_time})->epoch;
        $payload->{uuid}      = $uuid;

        Binary::WebSocketAPI::v3::Wrapper::Pricer::send_proposal_open_contract_last_time($c, $payload, $contract_id, $args);
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
        $c->send({json => $details});
        return;
    }

    $details->{transaction}->{transaction_time} = Date::Utility->new($payload->{sell_time} || $payload->{purchase_time})->epoch;

    # we need to fetch something from CONTRACT_PARAMS for multiplier option because transaction stream only streams short_code
    if ($payload->{short_code} =~ /^(?:MULTUP|MULTDOWN)/) {
        my $contract_id     = $payload->{financial_market_bet_id};
        my $lc              = $c->landing_company_name;
        my $contract_params = Binary::WebSocketAPI::v3::Wrapper::Pricer::get_contract_params($contract_id, $lc);

        unless (%$contract_params) {
            Binary::WebSocketAPI::v3::Wrapper::Pricer::fetch_contract_params_from_database($c, {contract_id => $contract_id});
            $contract_params = Binary::WebSocketAPI::v3::Wrapper::Pricer::get_contract_params($contract_id, $lc);
        }
        $payload->{limit_order} = $contract_params->{limit_order};
    }

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
                ($payload->{limit_order} ? (limit_order => $payload->{limit_order}) : ()),
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
                or $log->warnf(
                'Had no longcode for %s currency %s language %s',
                $payload->{short_code},
                $payload->{currency_code},
                $c->stash('language'));
            return Future->done;
        },
        sub {
            my ($error, $category, @details) = @_;
            $log->warn("Longcode failure, falling back to placeholder text - $error ($category: @details)");
            $payload->{longcode} = $c->l('Could not retrieve contract details');
            return Future->done;
        }
        )->then(
        sub {
            my $uuid = Binary::WebSocketAPI::v3::Wrapper::Pricer::pricing_channel_for_proposal_open_contract(
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
                    limit_order     => $payload->{limit_order},
                })->{uuid};

            # subscribe to transaction channel as when contract is manually sold we need to cancel streaming
            #TODO chylli test not cover here ?
            Binary::WebSocketAPI::v3::Wrapper::Transaction::transaction_channel($c, 'subscribe', $payload->{account_id},
                'sell', $poc_args, $payload->{financial_market_bet_id}, $uuid)
                if $uuid;
            return Future->done;
        });
}

1;

