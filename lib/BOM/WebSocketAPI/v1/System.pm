package BOM::WebSocketAPI::v1::System;

use strict;
use warnings;

sub forget {
    my ($c, $args) = @_;

    my $id = $args->{forget};

    Mojo::IOLoop->remove($id);
    if (my $fmb_id = eval { $c->{$id}->{fmb}->id }) {
        delete $c->{fmb_ids}{$fmb_id};
    }

    return {
        msg_type => 'forget',
        forget => delete $c->{$id} ? 1 : 0,
    };
}

sub ping {
    my ($c, $args) = @_;

    return {
        msg_type => 'ping',
        ping     => 'pong',
    };
}

1;
