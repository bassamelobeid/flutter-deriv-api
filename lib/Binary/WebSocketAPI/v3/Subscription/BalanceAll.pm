package Binary::WebSocketAPI::v3::Subscription::BalanceAll;
use strict;
use warnings;
no indirect;
use Moo;
use Scalar::Util qw(weaken);
use Format::Util::Numbers qw(formatnumber);
with 'Binary::WebSocketAPI::v3::Subscription';

use namespace::clean;

=head1 NAME

  Binary::WebSocketAPI::v3::Subscription::BalanceAll - The class that tracks all balances for the balance-all subscription

=head1 DESCRIPTION

This module tracks all balance for the balance-all subscription, it will not be used to subscribe the channel, but store information and emit out the result.

Please refer to L<Binary::WebSocketAPI::v3::Subscription::Transaction>

=head1 SYNOPSIS

    my $worker = Binary::WebSocketAPI::v3::Subscription::BalanceAll->new(
        c           => $c,
        args        => $args,
    );
    $worker->register;
    undef $worker; # Destroying the object

=cut

sub _unique_key {
    my $self = shift;
    return 'balance_all';
}

has total_currency => (
    is => 'ro',
);

has total_balance => (
    is => 'rw',
);

has subscriptions => (
    is  => 'rw',
    isa => sub { die "balances need an arrayref" unless ref($_[0]) eq 'ARRAY' },
    default => sub { [] },
);

sub add_subscription {
    my ($self, $subscription) = @_;
    $subscription->register;
    $subscription->subscribe;
    push @{$self->subscriptions}, $subscription;
    weaken($self->subscriptions->[-1]);
    return $self->subscriptions;
}

sub update_balance {
    my ($self, $subscription, $payload) = @_;
    my $args = $self->args;
    my $id   = $self->uuid;
    my $c    = $self->c;

    # currency_rate_in_total_currency will only be defined for real accounts
    $self->total_balance($self->total_balance + $payload->{amount} * $subscription->currency_rate_in_total_currency)
        if $subscription->currency_rate_in_total_currency && ($subscription->loginid // '') !~ /^VR/;

    my $details = {
        msg_type => 'balance',
        $args ? (echo_req => $args) : (),
        balance => {
            ($id ? (id => $id) : ()),
            loginid  => $subscription->loginid,
            currency => $subscription->currency,
            balance  => formatnumber('amount', $subscription->currency, $payload->{balance_after}),
            total    => {
                real => {
                    amount   => formatnumber('amount', $self->total_currency, $self->total_balance),
                    currency => $self->total_currency,
                    }

            }
        },
        $id ? (subscription => {id => $id}) : (),
    };
    $c->send({json => $details}) if $c->tx;
    return;

}

sub handle_message {
    die "This is a proxy module, no need to call handle_message";
}

sub subscription_manager {
    die "This is a proxy module, no need to call subscription_manager";
}

sub _build_channel {

}

before DEMOLISH => sub {
    my ($self, $global) = @_;
    return undef if $global;
    for my $subscription (@{$self->subscriptions}) {
        next unless $subscription;
        $subscription->unregister;
    }
};

1;
