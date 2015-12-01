package BOM::WebSocketAPI::v3::Wrapper::System;

use strict;
use warnings;

use BOM::WebSocketAPI::v3::Utility;
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

        if ($c->stash('feed_channel_type')) {
            foreach my $k (keys %{$c->stash('feed_channel_type')}) {
                $k =~ /(.*);(.*)/;
                my $fsymbol = $1;
                my $ftype   = $2;
                # . 's' while we are still using tickS in this calls. backward compatibility that must be removed.
                if (($ftype . 's') =~ /^$type/) {
                    push @removed_ids, $c->stash('feed_channel_type')->{$k}->{uuid};
                    BOM::WebSocketAPI::v3::MarketDiscovery::_feed_channel($c, 'unsubscribe', $fsymbol, $ftype);
                }
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

    if ($id =~ /-/ and $c->stash('feed_channel_type')) {
        foreach my $k (keys %{$c->stash('feed_channel_type')}) {
            $k =~ /(.*);(.*)/;
            if ($c->stash('feed_channel_type')->{$k}->{uuid} eq $id) {
                my $args = $c->stash('feed_channel_type')->{$k}->{args};
                BOM::WebSocketAPI::v3::MarketDiscovery::_feed_channel($c, 'unsubscribe', $1, $2);
                return $args;
            }
        }
    }

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
    }

    return $v;
}

sub ping {
    my ($c, $args) = @_;

    return {
        echo_req => $args,
        msg_type => 'ping',
        ping     => BOM::WebSocketAPI::v3::Utility::ping()};
}

sub server_time {
    my ($c, $args) = @_;

    return {
        echo_req => $args,
        msg_type => 'time',
        time     => BOM::WebSocketAPI::v3::Utility::server_time()};
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
