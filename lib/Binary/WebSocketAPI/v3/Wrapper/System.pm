package Binary::WebSocketAPI::v3::Wrapper::System;

use strict;
use warnings;

use Scalar::Util qw(looks_like_number);

use Binary::WebSocketAPI::v3::Wrapper::Streamer;

sub forget {
    my ($c, $req_storage) = @_;

    return {
        msg_type => 'forget',
        forget => forget_one($c, $req_storage->{args}->{forget}) ? 1 : 0,
    };
}
use Data::Dumper;

sub forget_all {
    my ($c, $req_storage) = @_;
    print "AAAAAAAAAA\n";
    print $req_storage->{args}->{forget_all} . "\n===================\n";
    print Dumper($req_storage);

    my %removed_ids;
    if (my $type = $req_storage->{args}->{forget_all}) {
        if ($type eq 'balance' or $type eq 'transaction' or $type eq 'proposal_open_contract') {
            @removed_ids{@{_forget_transaction_subscription($c, $type)}} = ();
        }
        if ($type eq 'proposal' or $type eq 'proposal_open_contract') {
            @removed_ids{@{_forget_all_pricing_subscriptions($c, $type)}} = ();
        }
        if ($type ne 'proposal_open_contract') {
            @removed_ids{@{_forget_feed_subscription($c, $type)}} = ();
        }
        if ($type eq 'proposal_array') {
            print "BBBBBBBBBB\n";
            @removed_ids{@{_forget_all_proposal_array($c)}} = ();
        }
    }
    return {
        msg_type   => 'forget_all',
        forget_all => [keys %removed_ids],
    };
}

sub _forget_all_proposal_array {
    my $c = shift;
    print "IIIIIIINNNNN _forget_all_proposal_array\n";

    my $proposal_array_subscriptions = $c->stash('proposal_array_subscriptions') // {};
    my $pa_keys = [keys %$proposal_array_subscriptions];
    print "pa_keys: " . Dumper($pa_keys);
    for my $pa_key (@$pa_keys) {
        print "Deleting $pa_key...\n";
        for my $uuid (keys %{$proposal_array_subscriptions->{$pa_key}{proposals}}) {
            print "forgeting $uuid\n";
            forget_one($c, $uuid);
        }
        delete $proposal_array_subscriptions->{$pa_key};
    }
    $c->stash(proposal_array_subscriptions => $proposal_array_subscriptions);

    return $pa_keys;
}

sub forget_one {
    my ($c, $id, $reason) = @_;
    print "FORGET ONE!!!!!!!!!!!!!!!!!!!!\n";

    my %removed_ids;
    if ($id && ($id =~ /-/)) {
        @removed_ids{@{_forget_feed_subscription($c, $id)}} = ();
        @removed_ids{@{_forget_transaction_subscription($c, $id)}} = ();
        @removed_ids{@{_forget_pricing_subscription($c, $id)}} = ();
        @removed_ids{@{_forget_proposal_array($c, $id)}} = ();
    }

    return scalar keys %removed_ids;
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
                Binary::WebSocketAPI::v3::Wrapper::Streamer::_transaction_channel($c, 'unsubscribe', $channel->{$type}->{account_id}, $type);
            }
        }
    }
    return $removed_ids;
}

sub _forget_proposal_array {
    my ($c, $id) = @_;
    my $proposal_array_subscriptions = $c->stash('proposal_array_subscriptions') // {};
    print "_forget_proposal_array: " . Dumper($proposal_array_subscriptions);
    if ($proposal_array_subscriptions->{$id}) {
        for my $uuid (keys %{$proposal_array_subscriptions->{$id}{proposals}}) {
            print "forgeting $uuid\n";
            _forget_pricing_subscription($c, $uuid);
        }
        delete $proposal_array_subscriptions->{$id};
        $c->stash(proposal_array_subscriptions => $proposal_array_subscriptions);
        return [$id];
    }
    return [];
}

sub _forget_pricing_subscription {
    my ($c, $uuid) = @_;
    my $removed_ids     = [];
    my $pricing_channel = $c->stash('pricing_channel');
    if ($pricing_channel) {
        foreach my $channel (keys %{$pricing_channel}) {
            foreach my $subchannel (keys %{$pricing_channel->{$channel}}) {
                next unless exists $pricing_channel->{$channel}->{$subchannel}->{uuid};
                if ($pricing_channel->{$channel}->{$subchannel}->{uuid} eq $uuid) {
                    push @$removed_ids, $pricing_channel->{$channel}->{$subchannel}->{uuid};
                    my $price_daemon_cmd = $pricing_channel->{uuid}->{$uuid}->{price_daemon_cmd};
                    delete $pricing_channel->{uuid}->{$uuid};
                    delete $pricing_channel->{$channel}->{$subchannel};
                    delete $pricing_channel->{price_daemon_cmd}->{$price_daemon_cmd}->{$uuid};
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
    my $price_daemon_cmd =
          $type eq 'proposal'               ? 'price'
        : $type eq 'proposal_open_contract' ? 'bid'
        :                                     undef;
    my $removed_ids     = [];
    my $pricing_channel = $c->stash('pricing_channel');
    if ($pricing_channel) {
        @$removed_ids = keys %{$pricing_channel->{price_daemon_cmd}->{$price_daemon_cmd}};
        foreach my $uuid (@$removed_ids) {
            my $redis_channel = $pricing_channel->{uuid}->{$uuid}->{redis_channel};
            if ($pricing_channel->{$redis_channel}) {
                $c->stash('redis_pricer')->unsubscribe([$redis_channel]);

                delete $pricing_channel->{$redis_channel};
            }
            delete $pricing_channel->{uuid}->{$uuid};
        }
        delete $pricing_channel->{price_daemon_cmd}->{$price_daemon_cmd};
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
            my ($fsymbol, $ftype, $req_id) = split(";", $channel);

            # forget all call sends strings like forget_all: candles|tick|proposal_open_contract
            if ($typeoruuid eq 'candles' and looks_like_number($ftype)) {
                push @$removed_ids, $subscription->{$channel}->{uuid};
                Binary::WebSocketAPI::v3::Wrapper::Streamer::_feed_channel_unsubscribe($c, $fsymbol, $ftype, $req_id);
            }
            # . 's' while we are still using ticks in this calls. backward compatibility that must be removed
            elsif (($ftype . 's') =~ /^$typeoruuid/) {
                push @$removed_ids, $subscription->{$channel}->{uuid};
                Binary::WebSocketAPI::v3::Wrapper::Streamer::_feed_channel_unsubscribe($c, $fsymbol, $ftype, $req_id);
            }
            # this is condition for forget call where we send unique id forget: id
            elsif ($typeoruuid eq $subscription->{$channel}->{uuid}) {
                push @$removed_ids, $subscription->{$channel}->{uuid};
                Binary::WebSocketAPI::v3::Wrapper::Streamer::_feed_channel_unsubscribe($c, $fsymbol, $ftype, $req_id);
            }
        }
    }
    return $removed_ids;
}

1;
