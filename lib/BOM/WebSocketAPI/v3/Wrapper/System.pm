package BOM::WebSocketAPI::v3::Wrapper::System;

use strict;
use warnings;

use Scalar::Util qw(looks_like_number);

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
        if ($type eq 'balance' or $type eq 'transaction') {
            $removed_ids = _forget_transaction_subscription($c, $type);
        } elsif ($type eq 'price_stream') {
            $removed_ids = _forget_all_pricing_subscriptions($c);
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
        # need to keep feed subscription first as in case of proposal_open_contract subscribes to transaction
        # channel and forgets transaction channel internally when we forget it
        $removed_ids = _forget_feed_subscription($c, $id) unless (scalar @$removed_ids);
        $removed_ids = _forget_transaction_subscription($c, $id) unless (scalar @$removed_ids);
        $removed_ids = _forget_pricing_subscription($c, $id) unless (scalar @$removed_ids);
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

sub _forget_transaction_subscription {
    my ($c, $typeoruuid) = @_;

    my $removed_ids = [];
    my $channel     = $c->stash('transaction_channel');
    if ($channel) {
        foreach my $type (keys %{$channel}) {
            if ($typeoruuid eq $type or $typeoruuid eq $channel->{$type}->{uuid}) {
                push @$removed_ids, $channel->{$type}->{uuid};
                BOM::WebSocketAPI::v3::Wrapper::Streamer::_transaction_channel($c, 'unsubscribe', $channel->{$type}->{account_id}, $type);
            }
        }
    }
    return $removed_ids;
}

sub _forget_pricing_subscription {
    my ($c, $uuid) = @_;
    my $removed_ids     = [];
    my $pricing_channel = $c->stash('pricing_channel');
    if ($pricing_channel) {
        foreach my $channel (keys %{$pricing_channel}) {
            foreach my $amount (keys %{$pricing_channel->{$channel}}) {
                next if $amount eq 'channel_name';
                if ($pricing_channel->{$channel}->{$amount}->{uuid} eq $uuid) {
                    push @$removed_ids, $pricing_channel->{$channel}->{$amount}->{uuid};
                    delete $pricing_channel->{$channel}->{$amount};
                }
            }

            if (scalar keys %{$pricing_channel->{$channel}} == 1) {
                $c->stash('redis')->unsubscribe([$pricing_channel->{$channel}->{channel_name}]);
                delete $pricing_channel->{$channel};
            }
        }
        $c->stash('pricing_channel' => $pricing_channel);
    }

    return $removed_ids;
}

sub _forget_all_pricing_subscriptions {
    my ($c, $uuid)      = @_;
    my $removed_ids     = [];
    my $pricing_channel = $c->stash('pricing_channel');
    if ($pricing_channel) {
        if ($uuid) {
            return if not exists $pricing_channel->{uuid}->{$uuid};
            my $serialized_args = $pricing_channel->{uuid}->{$uuid}->{serialized_args};
            my $amount          = $pricing_channel->{uuid}->{$uuid}->{amount};
            delete  $pricing_channel->{uuid}->{$uuid};
            delete  $pricing_channel->{$serialized_args}->{$amount};
            if (scalar keys %{$pricing_channel->{$serialized_args}} == 0) {
                $c->stash('redis')->unsubscribe([$pricing_channel->{$serialized_args}->{channel_name}]);
                delete $pricing_channel->{$serialized_args};
            }
            push @$removed_ids, $uuid;
            $c->stash('pricing_channel' => $pricing_channel);
            return $removed_ids;
        }
        foreach my $serialized_args (keys %{$pricing_channel}) {
            $c->stash('redis')->unsubscribe([$pricing_channel->{$serialized_args}->{channel_name}]);
            delete $pricing_channel->{$serialized_args};
        }
        delete $pricing_channel->{uuid};
        $c->stash('pricing_channel' => $pricing_channel);
    }
    return $removed_ids;
}

sub _forget_feed_subscription {
    my ($c, $typeoruuid) = @_;
    my $removed_ids  = [];
    my $subscription = $c->stash('feed_channel_type');
    if ($subscription) {
        foreach my $channel (keys %{$subscription}) {
            $channel =~ /(.*);(.*)/;
            my $fsymbol = $1;
            my $ftype   = $2;
            # . 's' while we are still using tickS in this calls. backward compatibility that must be removed
            if ($typeoruuid eq 'candles' and looks_like_number($ftype)) {
                push @$removed_ids, $subscription->{$channel}->{uuid};
                BOM::WebSocketAPI::v3::Wrapper::Streamer::_feed_channel($c, 'unsubscribe', $fsymbol, $ftype);
            } elsif (($ftype . 's') =~ /^$typeoruuid/ or $typeoruuid eq $subscription->{$channel}->{uuid}) {
                push @$removed_ids, $subscription->{$channel}->{uuid};
                BOM::WebSocketAPI::v3::Wrapper::Streamer::_feed_channel($c, 'unsubscribe', $fsymbol, $ftype);
            }
        }
    }
    return $removed_ids;
}

# its separate, cos for proposal we need args that are used as contract parameters for buy
# only difference from _forget_feed_subscription is return type and value
sub forget_buy_proposal {
    my ($c, $uuid) = @_;
    my $subscription = $c->stash('feed_channel_type');
    if ($uuid =~ /-/ and $subscription) {
        foreach my $channel (keys %{$subscription}) {
            $channel =~ /(.*);(.*)/;
            if ($subscription->{$channel}->{uuid} eq $uuid) {
                my $args = $subscription->{$channel}->{args};
                BOM::WebSocketAPI::v3::Wrapper::Streamer::_feed_channel($c, 'unsubscribe', $1, $2);
                return $args;
            }
        }
    }
    return;
}

1;
