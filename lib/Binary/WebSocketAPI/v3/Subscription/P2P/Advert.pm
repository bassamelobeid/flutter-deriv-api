package Binary::WebSocketAPI::v3::Subscription::P2P::Advert;

use strict;
use warnings;
no indirect;

=head1 NAME

Binary::WebSocketAPI::v3::Subscription::P2P::Advert

=head1 DESCRIPTION

Handles p2p_advert_info subscriptions.

=cut

use Moo;
with 'Binary::WebSocketAPI::v3::Subscription';

use DataDog::DogStatsd::Helper qw(stats_inc);

has loginid       => (is => 'ro');
has account_id    => (is => 'ro');
has advert_id     => (is => 'ro');
has advertiser_id => (is => 'ro');

sub subscription_manager {
    return Binary::WebSocketAPI::v3::SubscriptionManager->redis_p2p_manager();
}

sub _build_channel {
    my $self = shift;
    return join '::', 'P2P::ADVERT', $self->advertiser_id, $self->account_id, $self->loginid, ($self->advert_id // 'ALL');
}

# This method is used to find a subscription.
# Class name + _unique_key will be a unique per context index of the subscription objects.
sub _unique_key {
    my $self = shift;
    return $self->channel;
}

=head2 handle_message

Handle incoming subscription messages.

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
                msg_type => 'p2p_advert_info',
                echo_req => $args,
                (exists $args->{req_id})
                ? (req_id => $args->{req_id})
                : (),
                p2p_advert_info => $payload,
                subscription    => {id => $self->uuid},
            }});

    $self->unregister if $payload->{deleted};

    return;
}

1;
