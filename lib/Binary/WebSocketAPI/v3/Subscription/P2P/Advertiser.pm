package Binary::WebSocketAPI::v3::Subscription::P2P::Advertiser;

use strict;
use warnings;
no indirect;

use feature 'state';

=head1 NAME

Binary::WebSocketAPI::v3::Subscription::P2P::Advertiser

=head1 DESCRIPTION

L<Binary::WebSocketAPI::v3::Subscription>

=cut

use Moo;
with 'Binary::WebSocketAPI::v3::Subscription';

use DataDog::DogStatsd::Helper qw(stats_inc);

has loginid => (
    is       => 'ro',
    required => 1,
);

has advertiser_loginid => (
    is       => 'ro',
    required => 1,
);

sub subscription_manager {
    return Binary::WebSocketAPI::v3::SubscriptionManager->redis_p2p_manager();
}

sub _build_channel {
    my $self = shift;
    return join q{::} => map { uc($_) } ('P2P::ADVERTISER::NOTIFICATION', $self->advertiser_loginid, $self->loginid);
}

# This method is used to find a subscription.
# Class name + _unique_key will be a unique per context index of the subscription objects.
sub _unique_key {
    my $self = shift;
    return $self->channel;
}

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
                msg_type => 'p2p_advertiser_info',
                echo_req => $args,
                (exists $args->{req_id})
                ? (req_id => $args->{req_id})
                : (),
                p2p_advertiser_info => $payload,
                subscription        => {id => $self->uuid},
            }});
    return;
}

1;
