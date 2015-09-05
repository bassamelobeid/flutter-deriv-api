package BOM::WebSocketAPI::v2::System;

use strict;
use warnings;

sub forget {
    my ($c, $args) = @_;

    my $id = $args->{forget};

    Mojo::IOLoop->remove($id);
    if (my $fmb_id = eval { $c->{$id}->{fmb}->id }) {
        delete $c->{fmb_ids}{$fmb_id};
    }

    my $ws_id  = $c->tx->connection;
    return {
        msg_type => 'forget',
        forget => delete $c->{ws}{$ws_id}{$id} ? 1 : 0,
    };
}

sub ping {
    my ($c, $args) = @_;

    return {
        msg_type => 'ping',
        ping     => 'pong',
    };
}

sub server_time {
    my ($c, $args) = @_;

    return {
        msg_type => 'time',
        time     => time,
    };
}

## limit total stream count to 50
sub _limit_stream_count {
    my ($c) = @_;

    my $ws_id  = $c->tx->connection;
    my @ws_ids = keys %{$c->{ws}{$ws_id}};

    return if scalar(@ws_ids) <= 50;

    # remove first b/c we added one
    @ws_ids = sort { $c->{ws}{$ws_id}{$a}{started} <=> $c->{ws}{$ws_id}{$b}{started} } @ws_ids;
    Mojo::IOLoop->remove($ws_ids[0]);
    my $v = delete $c->{ws}{$ws_id}{$ws_ids[0]};
    if ($v->{type} eq 'portfolio' || $v->{type} eq 'proposal_open_contract') {
        delete $c->{fmb_ids}{$v->{fmb}->id};
    }
}

1;
