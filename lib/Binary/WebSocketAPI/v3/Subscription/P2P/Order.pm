package Binary::WebSocketAPI::v3::Subscription::P2P::Order;

use strict;
use warnings;
no indirect;

=head1 NAME

Binary::WebSocketAPI::v3::Subscription::P2P::Order

=head1 DESCRIPTION

L<Binary::WebSocketAPI::v3::Subscription>

=cut

use Moo::Role;

with 'Binary::WebSocketAPI::v3::Subscription';

use DataDog::DogStatsd::Helper qw(stats_inc);

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
                msg_type => 'p2p_order',
                echo_req => $args,
                (exists $args->{req_id})
                ? (req_id => $args->{req_id})
                : (),
                p2p_order    => $payload,
                subscription => {id => $self->uuid},
            }});
    return;
}

1;
