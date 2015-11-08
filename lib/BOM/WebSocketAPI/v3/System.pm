package BOM::WebSocketAPI::v3::System;

use strict;
use warnings;

use Mojo::Util qw(md5_sum steady_time);

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
        my $ws_id  = $c->tx->connection;
        my $this_c = ($c->{ws}{$ws_id} //= {});
        my $list   = ($this_c->{l} //= []);
        my @dummy  = @$list;                      # must copy b/c forget_one modifies @$list

        for my $v (@dummy) {
            if ($v->{type} eq $type and forget_one($c, $v->{id})) {
                push @removed_ids, $v->{id};
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

    my $ws_id  = $c->tx->connection;
    my $this_c = ($c->{ws}{$ws_id} //= {});
    my $list   = ($this_c->{l} //= []);
    my $hash   = ($this_c->{h} //= {});

    my $v = delete $hash->{$id};
    return unless $v;
    @$list = grep { $_->{id} ne $id } @$list;

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

sub _id {
    my ($hash) = @_;

    my $id;
    do { $id = md5_sum steady_time . rand 999 } while $hash->{$id};

    return $id;
}

## limit total stream count to 50
sub limit_stream_count {    ## no critic (Subroutines::RequireFinalReturn)
    my ($c, $data) = @_;

    my $ws_id  = $c->tx->connection;
    my $this_c = ($c->{ws}{$ws_id} //= {});
    my $list   = ($this_c->{l} //= []);
    my $hash   = ($this_c->{h} //= {});

    my $id = ($data->{id} //= _id($hash));
    forget_one $c, $id, 'StreamCountLimitReached'
        if exists $hash->{$id};

    push @$list, $data;
    $hash->{$id} = $data;

    return $id if scalar(@$list) <= 50;

    forget_one $c, $list->[0]->{id}, 'StreamCountLimitReached';

    return $id;
}

1;
