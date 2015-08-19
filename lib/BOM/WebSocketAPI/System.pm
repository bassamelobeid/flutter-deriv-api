package BOM::WebSocketAPI::System;

use strict;
use warnings;

sub forget {
    my ($c, $id) = @_;
    Mojo::IOLoop->remove($id);
    if (my $fmb_id = eval { $c->{$id}->{fmb}->id }) {
        delete $c->{fmb_ids}{$fmb_id};
    }
    delete $c->{$id};
    return;
}

1;
