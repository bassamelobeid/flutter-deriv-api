package BOM::WebSocketAPI::v3::Wrapper::System;

use strict;
use warnings;

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

    my $removed_ids = [];
    if (my $type = $args->{forget_all}) {
        if ($type eq 'balance') {
            $removed_ids = _forget_balance_subscription($c, $type);
        } elsif ($type eq 'transaction') {
            $removed_ids = _forget_transaction_subscription($c, $type);
        } else {
            $removed_ids = _forget_feed_subscription($c, $type);
        }
    }

    return {
        msg_type   => 'forget_all',
        forget_all => $removed_ids
    };
}

sub forget_one {
    my ($c, $id, $reason) = @_;

    my $removed_ids = [];
    if ($id =~ /-/) {
        $removed_ids = _forget_balance_subscription($c, $id);
        $removed_ids = _forget_transaction_subscription($c, $id) unless (scalar @$removed_ids);
        $removed_ids = _forget_feed_subscription($c, $id) unless (scalar @$removed_ids);
    }

    return scalar @$removed_ids;
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

sub website_status {
    my ($c, $args) = @_;

    return {
        msg_type       => 'website_status',
        website_status => BOM::RPC::v3::Utility::website_status($c->app_config),
    };
}

sub _forget_balance_subscription {
    my ($c, $typeoruuid) = @_;
    my $removed_ids  = [];
    my $subscription = $c->stash('subscribed_channels');
    if ($subscription) {
        foreach my $channel (keys %{$subscription}) {
            if ($typeoruuid eq $subscription->{$channel}->{type} or $typeoruuid eq $subscription->{$channel}->{uuid}) {
                push @$removed_ids, $subscription->{$channel}->{uuid};
                BOM::WebSocketAPI::v3::Wrapper::Streamer::_balance_channel($c, 'unsubscribe', $subscription->{$channel}->{account_id});
            }
        }
    }
    return $removed_ids;
}

sub _forget_transaction_subscription {
    my ($c, $typeoruuid) = @_;
    my $removed_ids  = [];
    my $subscription = $c->stash('transaction_channel');
    if ($subscription) {
        foreach my $channel (keys %{$subscription}) {
            if ($typeoruuid eq $subscription->{$channel}->{type} or $typeoruuid eq $subscription->{$channel}->{uuid}) {
                push @$removed_ids, $subscription->{$channel}->{uuid};
                BOM::WebSocketAPI::v3::Wrapper::Streamer::_transaction_channel($c, 'unsubscribe', $subscription->{$channel}->{account_id});
            }
        }
    }
    return $removed_ids;
}

sub _forget_feed_subscription {
    my ($c, $uuid) = @_;
    my $removed_ids  = [];
    my $subscription = $c->stash('feed_channel_type');
    if ($subscription) {
        foreach my $channel (keys %{$subscription}) {
            $channel =~ /(.*);(.*)/;
            my $fsymbol = $1;
            my $ftype   = $2;
            # . 's' while we are still using ticks in this calls. backward compatibility that must be removed.
            if (($ftype . 's') =~ /^$uuid/) {
                push @$removed_ids, $subscription->{$channel}->{uuid};
                BOM::WebSocketAPI::v3::Wrapper::Streamer::_feed_channel($c, 'unsubscribe', $fsymbol, $ftype);
            }
        }
    }
    return $removed_ids;
}

1;
