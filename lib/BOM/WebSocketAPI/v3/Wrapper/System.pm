package BOM::WebSocketAPI::v3::Wrapper::System;

use strict;
use warnings;

use Scalar::Util qw(looks_like_number);

use BOM::WebSocketAPI::v3::Wrapper::Streamer;

sub forget {
    my ($c, $req_storage) = @_;

    return {
        msg_type => 'forget',
        forget => forget_one($c, $req_storage->{args}->{forget}) ? 1 : 0,
    };
}

sub forget_all {
    my ($c, $req_storage) = @_;

    my $removed_ids = {};
    my $type = $req_storage->{args}->{forget_all};
    if (my $type = $req_storage->{args}->{forget_all}) {
        if ($type eq 'balance' or $type eq 'transaction' or $type eq 'proposal_open_contract') {
            $removed_ids->{$_} = 1 for @{_forget_transaction_subscription($c, $type)};
        }
        if ($type eq 'proposal' or $type eq 'proposal_open_contract') {
            $removed_ids->{$_} = 1 for @{_forget_all_pricing_subscriptions($c, $type)};
        }
        if ($type ne 'proposal_open_contract') {
            $removed_ids->{$_} = 1 for @{_forget_feed_subscription($c, $type)};
        }
    }

    return {
        msg_type   => 'forget_all',
        forget_all => [keys %$removed_ids],
    };
}

sub forget_one {
    my ($c, $id, $reason) = @_;

    my $removed_ids = {};
    if ($id && ($id =~ /-/)) {
        $removed_ids_>{$_} = 1 for @{_forget_feed_subscription($c, $id)};
        $removed_ids->{$_} = 1 for @{_forget_transaction_subscription($c, $id)};
        $removed_ids->{$_} = 1 for @{_forget_pricing_subscription($c, $id)};
    }

    return scalar keys %$removed_ids;
}

sub ping {
    return {
        msg_type => 'ping',
        ping     => 'pong'
    };
}

sub server_time {
    return {
        'msg_type' => 'time',
        'time'     => time
    };
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
            foreach my $subchannel (keys %{$pricing_channel->{$channel}}) {
                next unless ref $pricing_channel->{$channel}->{$subchannel};
                next unless exists $pricing_channel->{$channel}->{$subchannel}->{uuid};
                if ($pricing_channel->{$channel}->{$subchannel}->{uuid} eq $uuid) {
                    push @$removed_ids, $pricing_channel->{$channel}->{$subchannel}->{uuid};
                    my $rpc_call = $pricing_channel->{uuid}->{$uuid}->{rpc_call};
                    delete $pricing_channel->{uuid}->{$uuid};
                    delete $pricing_channel->{$channel}->{$subchannel};
                    delete $pricing_channel->{$rpc_call}->{$uuid};
                }
            }

            if (scalar keys %{$pricing_channel->{$channel}} == 0) {
                $c->stash('redis_pricer')->unsubscribe([$channel]);
                delete $pricing_channel->{$channel};
            }
        }
        $c->stash('pricing_channel' => $pricing_channel);
    }

    return $removed_ids;
}

sub _forget_all_pricing_subscriptions {
    my ($c, $type) = @_;
    my $rpc_call = {proposal => 'send_ask', proposal_open_contract => 'send_bid'}->{$type};
    my $removed_ids     = [];
    my %channels_to_check;
    my $pricing_channel = $c->stash('pricing_channel');
    if ($pricing_channel) {
        foreach my $uuid (keys %{$pricing_channel->{$rpc_call}}) {
            push @$removed_ids, $uuid;
            my $redis_channel = $pricing_channel->{uuid}->{$uuid}->{redis_channel};
            my $subchannel    = $pricing_channel->{uuid}->{$uuid}->{subchannel};
            $channels_to_check{$redis_channel} = 1;
            delete $pricing_channel->{$redis_channel}->{$subchannel};
            delete $pricing_channel->{uuid}->{$uuid};
        }
        for my $redis_channel (keys %channels_to_check) {
            unless (keys %{$pricing_channel->{$redis_channel}}) {
                $c->stash('redis_pricer')->unsubscribe([$redis_channel]);
                delete $pricing_channel->{$redis_channel};
            }
        }
        delete $pricing_channel->{$rpc_call};
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
