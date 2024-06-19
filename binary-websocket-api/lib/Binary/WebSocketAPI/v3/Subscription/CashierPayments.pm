package Binary::WebSocketAPI::v3::Subscription::CashierPayments;

use strict;
use warnings;
no indirect;

use feature 'state';

=head1 NAME

Binary::WebSocketAPI::v3::Subscription::CashierPayments

=head1 DESCRIPTION

L<Binary::WebSocketAPI::v3::Subscription>

=cut

use Moo;
with 'Binary::WebSocketAPI::v3::Subscription';

use DataDog::DogStatsd::Helper qw(stats_inc);

=head2 loginid

The C<loginid> attribute

=cut

has loginid => (
    is       => 'ro',
    required => 1,
);

=head2 transaction_type

The C<transaction_type> attribute

=cut

has transaction_type => (
    is       => 'ro',
    required => 1,
);

=head2 subscription_manager

The L<Binary::WebSocketAPI::v3::SubscriptionManager> instance that will manage this worker.

=cut

sub subscription_manager {
    return Binary::WebSocketAPI::v3::SubscriptionManager->redis_transaction_manager();
}

=head2 _build_channel

Make the channel name.

=cut

sub _build_channel {
    my $self = shift;
    return join q{::} => map { uc } ('CASHIER::PAYMENTS', $self->loginid);
}

=head2 _unique_key

This method is used to find a subscription.

=cut

sub _unique_key {
    my $self = shift;
    return join q{::} => ($self->channel, $self->transaction_type);
}

=head2 handle_message

Process the message.
Please refer to L<Binary::WebSocketAPI::v3::Subscription/handle_message>

=cut

sub handle_message {
    my ($self, $payload) = @_;
    my $c = $self->c;

    unless ($c->tx) {
        $self->unregister;
        return;
    }

    return if ($self->loginid ne $payload->{client_loginid});

    if ($self->transaction_type ne 'all') {
        my @crypto = grep { $self->transaction_type eq $_->{transaction_type} } $payload->{crypto}->@*;
        return unless @crypto;
        $payload->{crypto} = [@crypto];
    }

    # Need to localize messages here since WS is the only source for the language of each subscription.
    for my $txn ($payload->{crypto}->@*) {
        $txn->{status_message} = $c->l($txn->{status_message});
    }

    delete $payload->{client_loginid};

    my $args = $self->args;
    $c->send({
            json => {
                msg_type => 'cashier_payments',
                echo_req => $args,
                (exists $args->{req_id}) ? (req_id => $args->{req_id}) : (),
                cashier_payments => $payload,
                subscription     => {id => $self->uuid},
            },
        });

    return;
}

1;
