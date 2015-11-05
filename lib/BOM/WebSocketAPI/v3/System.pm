package BOM::WebSocketAPI::v3::System;

use strict;
use warnings;

sub forget {
    my ($c, $args) = @_;

    return {
        msg_type => 'forget',
        forget => forget_one($c, $args->{forget}) ? 1 : 0,
    };
}

sub forget_all {
    my ($c, $args) = @_;

    my @removed_ids;

    if (my $type = $args->{forget_all}) {
        my $ws_id = $c->tx->connection;
        foreach my $id (keys %{$c->{ws}{$ws_id}}) {
            if ($c->{ws}{$ws_id}{$id}{type} eq $type) {
                push @removed_ids, $id if forget_one($c, $id);
            }
        }
    }

    return {
        msg_type   => 'forget_all',
        forget_all => \@removed_ids
    };
}

sub forget_one {
    my ($c, $id, $reason) = @_;

    my $ws_id = $c->tx->connection;
    my $v     = delete $c->{ws}{$ws_id}{$id};
    return unless $v;

    if (exists $v->{cleanup}) {
        $v->{cleanup}->($reason);
    } else {
        Mojo::IOLoop->remove($id);
        if ($v->{type} eq 'proposal_open_contract') {
            delete $c->{fmb_ids}{$ws_id}{$v->{fmb}->id};
        }
    }

    return $v;
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
sub _limit_stream_count {    ## no critic (Subroutines::RequireFinalReturn)
    my ($c) = @_;

    my $ws_id  = $c->tx->connection;
    my $this_c = ($c->{ws}{$ws_id} //= {});
    my @ids    = keys %$this_c;

    return if scalar(@ids) <= 50;

    # remove first b/c we added one
    @ids = sort { $this_c->{$a}{started} <=> $this_c->{$b}{started} } @ids;

    forget_one $c, $ids[0], 'StreamCountLimitReached';
}

1;
