package Binary::WebSocketAPI::v3::Subscription::CryptoEstimations;

use strict;
use warnings;
no indirect;

use feature 'state';

=head1 NAME

Binary::WebSocketAPI::v3::Subscription::CryptoEstimations

=head1 DESCRIPTION

This module deals with Crypto Estimations channel subscriptions.
Please refer to L<Binary::WebSocketAPI::v3::Subscription>

=cut

use Moo;
with 'Binary::WebSocketAPI::v3::Subscription';

use DataDog::DogStatsd::Helper qw(stats_inc);

=head2 currency_code

The C<currency_code> attribute

=cut

has currency_code => (
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

sub _build_channel { return 'CRYPTOCASHIER::ESTIMATIONS::FEE::' . shift->currency_code }

=head2 _unique_key

This method is used to find a subscription.

=cut

sub _unique_key { shift->channel }

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

    my $args = $self->args;
    $c->send({
            json => {
                msg_type => 'crypto_estimations',
                echo_req => $args,
                (exists $args->{req_id})
                ? (req_id => $args->{req_id})
                : (),
                crypto_estimations => {$self->currency_code => $payload},
                subscription       => {id                   => $self->uuid},
            }});
    return;
}

1;
