package Binary::WebSocketAPI::v3::Subscription::P2P::Order;

use strict;
use warnings;
no indirect;

use feature 'state';

=head1 NAME

Binary::WebSocketAPI::v3::Subscription::P2P::Order

=head1 DESCRIPTION

L<Binary::WebSocketAPI::v3::Subscription>

=cut

use Moo;
with 'Binary::WebSocketAPI::v3::Subscription';

use DataDog::DogStatsd::Helper qw(stats_inc);

has broker => (
    is       => 'ro',
    required => 1,
    isa      => sub {
        ;
        die "brocker can only be a string which contains 2-4 chars: $_[0]" unless $_[0] =~ /^\w{2,4}$/;
    });

has loginid => (
    is       => 'ro',
    required => 1,
);

has currency => (
    is       => 'ro',
    required => 1,
    isa      => sub {
        ;
        die "currency can only be a string which contains 3 chars: $_[0]" unless $_[0] =~ /^\w{3,}$/;
    });

has country => (
    is       => 'ro',
    required => 1,
    isa      => sub {
        ;
        die "country can only be a string which contains 2 chars: $_[0]" unless $_[0] =~ /^\w{2}$/;
    });

has order_id => (is => 'ro');

sub subscription_manager {
    return Binary::WebSocketAPI::v3::SubscriptionManager->redis_p2p_manager();
}

sub _build_channel {
    my $self = shift;
    return join q{::} => map { uc($_) } ('P2P::ORDER::NOTIFICATION', $self->broker, $self->country, $self->currency);
}

# This method is used to find a subscription.
# Class name + _unique_key will be a unique per context index of the subscription objects.
sub _unique_key {
    my $self = shift;
    return join q{::} => ($self->channel, $self->order_id // '');
}

sub handle_message {
    my ($self, $payload) = @_;
    my $c = $self->c;
    unless ($c->tx) {
        $self->unregister;
        return;
    }

    return
        if ($payload->{advertiser_loginid} // '') ne $self->loginid
        && ($payload->{client_loginid} // '') ne $self->loginid;

    delete @{$payload}{qw(advertiser_loginid client_loginid)};

    return if $self->order_id && $self->order_id ne $payload->{id};

    my $args = $self->args;
    $c->send({
            json => {
                msg_type => 'p2p_order_info',
                echo_req => $args,
                (exists $args->{req_id})
                ? (req_id => $args->{req_id})
                : (),
                p2p_order_info => $payload,
                subscription   => {id => $self->uuid},
            }});
    return;
}

1;
