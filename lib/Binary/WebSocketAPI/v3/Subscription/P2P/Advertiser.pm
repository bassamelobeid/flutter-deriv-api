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

has advertiser_id => (
    is       => 'ro',
    required => 1,
);

sub subscription_manager {
    return Binary::WebSocketAPI::v3::SubscriptionManager->redis_p2p_manager();
}

sub _build_channel {
    my $self = shift;
    return join q{::} => map { uc($_) } ('P2P::ADVERTISER::NOTIFICATION', $self->broker);
}

# This method is used to find a subscription.
# Class name + _unique_key will be a unique per context index of the subscription objects.
sub _unique_key {
    my $self = shift;
    return join q{::} => ($self->channel, $self->advertiser_id);
}

sub handle_message {
    my ($self, $payload) = @_;
    my $c = $self->c;

    unless ($c->tx) {
        $self->unregister;
        return;
    }

    return if $self->advertiser_id ne $payload->{id};

    if ($self->loginid ne $payload->{client_loginid}) {
        delete @{$payload}
            {qw(contact_info payment_info chat_user_id chat_token daily_buy daily_sell daily_buy_limit daily_sell_limit show_name balance_available)};
    }

    delete $payload->{client_loginid};

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
