package BOM::WebSocketAPI::v3::Wrapper::System;

use strict;
use warnings;

use Mojo::Util qw(md5_sum steady_time);

use BOM::RPC::v3::Utility;
use BOM::WebSocketAPI::v3::Wrapper::Streamer;

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
        if ($c->stash('feed_channel_type')) {
            foreach my $k (keys %{$c->stash('feed_channel_type')}) {
                $k =~ /(.*);(.*)/;
                my $fsymbol = $1;
                my $ftype   = $2;
                # . 's' while we are still using tickS in this calls. backward compatibility that must be removed.
                if (($ftype . 's') =~ /^$type/) {
                    push @removed_ids, $c->stash('feed_channel_type')->{$k}->{uuid};
                    BOM::WebSocketAPI::v3::Wrapper::Streamer::_feed_channel($c, 'unsubscribe', $fsymbol, $ftype);
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
                BOM::WebSocketAPI::v3::Wrapper::Streamer::_feed_channel($c, 'unsubscribe', $1, $2);
                return $args;
            }
        }
    }

    return;
}

sub ping {
    my ($c, $args) = @_;

    return {
        msg_type => 'ping',
        ping     => BOM::RPC::v3::Utility::ping()};
}

sub server_time {
    my ($c, $args) = @_;

    return {
        msg_type => 'time',
        time     => BOM::RPC::v3::Utility::server_time()};
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
