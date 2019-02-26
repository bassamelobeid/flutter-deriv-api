package Binary::WebSocketAPI::v3::Wrapper::System;

use strict;
use warnings;

use Scalar::Util qw(looks_like_number);
use Array::Utils qw(array_minus);

use Binary::WebSocketAPI::v3::Wrapper::Streamer;
use Binary::WebSocketAPI::v3::Instance::Redis qw(ws_redis_master);
use DataDog::DogStatsd::Helper qw(stats_dec);

sub forget {
    my ($c, $req_storage) = @_;

    return {
        msg_type => 'forget',
        forget => forget_one($c, $req_storage->{args}->{forget}) ? 1 : 0,
    };
}

# forgeting all stream which need authentication after logout
sub forget_after_logout {
    my $c = shift;

    Binary::WebSocketAPI::v3::Wrapper::System::_forget_transaction_subscription($c, 'balance');
    Binary::WebSocketAPI::v3::Wrapper::System::_forget_transaction_subscription($c, 'transaction');
    Binary::WebSocketAPI::v3::Wrapper::System::_forget_transaction_subscription($c, 'proposal_open_contract');
    Binary::WebSocketAPI::v3::Wrapper::System::_forget_all_pricing_subscriptions($c, 'proposal_open_contract');
    Binary::WebSocketAPI::v3::Wrapper::System::_forget_feed_subscription($c, 'proposal_open_contract');
    return;
}

sub forget_all {
    my ($c, $req_storage) = @_;

    my %removed_ids;
    if (my $types = $req_storage->{args}->{forget_all}) {
        # if type is a string, turn it into an array
        $types = [$types] unless ref($types) eq 'ARRAY';
        # since we accept array, syntax check should be done here
        # TODO: move this to anyOf in JSON schema after anyOf usage in schema is fixed
        my $accepted_types = qr/^(ticks|candles|proposal|proposal_open_contract|balance|transaction|proposal_array|website_status)$/;
        my @failed_types = grep { !/$accepted_types/ } @$types;
        return $c->new_error('forget_all', 'InputValidationFailed', $c->l('Input validation failed: ') . join(', ', @failed_types)) if @failed_types;

        for my $type (@$types) {
            if ($type eq 'website_status') {
                @removed_ids{@{_forget_all_website_status($c)}} = ();
                next;
            }
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
                @removed_ids{@{_forget_all_proposal_array($c)}} = ();
            }
        }
    }
    return {
        msg_type   => 'forget_all',
        forget_all => [keys %removed_ids],
    };
}

sub _forget_all_proposal_array {
    my $c = shift;

    my $proposal_array_subscriptions = $c->stash('proposal_array_subscriptions') // {};
    my $pa_keys = [keys %$proposal_array_subscriptions];
    for my $pa_key (@$pa_keys) {
        forget_one($c, $_) for keys %{$proposal_array_subscriptions->{$pa_key}{proposals}};
        delete $proposal_array_subscriptions->{$pa_key};
        # proposal_array also creates 'price' subscription for itself while obtains uuid - so delete it too
        _forget_pricing_subscription($c, $pa_key);
    }
    $c->stash(proposal_array_subscriptions => $proposal_array_subscriptions);

    return $pa_keys;
}

=head2 _forget_all_website_status

Cancels an existing subscription to B<website_status> stream.

Example usage:

Takes the following arguments

=over 4

=item * C<$c> - websocket connection object

=item * C<$id> - a uuid representig the subscription to be teminated (optional).

=back 

Returns an array ref containg uuid of subscriptions effectively cancelled.

=cut

sub _forget_all_website_status {
    my ($c, $id) = @_;

    my $connection_id = $c + 0;
    my $redis         = ws_redis_master();

    return [] unless $redis->{shared_info}->{broadcast_notifications}{$connection_id};

    my $uuid = $redis->{shared_info}->{broadcast_notifications}{$connection_id}->{uuid} // '';

    return [] if $id and ($id ne $uuid);

    delete $redis->{shared_info}->{broadcast_notifications}->{$connection_id};

    return $uuid ? [$uuid] : [];
}

sub forget_one {
    my ($c, $id, $reason) = @_;

    my %removed_ids;
    if ($id && ($id =~ /-/)) {
        @removed_ids{@{_forget_feed_subscription($c, $id)}} = ();
        @removed_ids{@{_forget_transaction_subscription($c, $id)}} = ();
        @removed_ids{@{_forget_pricing_subscription($c, $id)}} = ();
        @removed_ids{@{_forget_proposal_array($c, $id)}} = ();
        @removed_ids{@{_forget_all_website_status($c, $id)}} = ();

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
    my $channel = $c->stash('transaction_channel') // {};
    for my $k (keys %$channel) {
        # $k never could be 'proposal_open_contract', so we will not return any uuids related to proposal_open_contract subscriptions
        push @$removed_ids, $channel->{$k}->{uuid} if $typeoruuid eq $k or $typeoruuid eq $channel->{$k}->{uuid};
        # but we have to remove them as well when forget_all:proposal_open_contract is called
        Binary::WebSocketAPI::v3::Wrapper::Streamer::transaction_channel($c, 'unsubscribe', $channel->{$k}->{account_id}, $k)
            if $typeoruuid eq $k
            or $typeoruuid eq $channel->{$k}->{uuid}
            # $typeoruuid could be 'proposal_open_contract' only in case when forget_all is called with 'proposal_open_contract' as an argument
            # proposal_open_contract sunbscription in fact creates two subscriptions:
            #   - for pricer - getting bids
            #   - and for transactions - waiting contract sell event
            # so pricer subscription will be removed by '_forget_all_pricing_subscriptions' call (and list of uuids to return will be generated)
            # and here we just removing appropriate transaction subscriptions - which (and only) keys are always uuids
            or $typeoruuid eq 'proposal_open_contract' and $k =~ /\w{8}-\w{4}-\w{4}-\w{4}-\w{12}/;    # forget_all:proposal_open_contract case
    }
    return $removed_ids;
}

sub _forget_proposal_array {
    my ($c, $id) = @_;
    my $proposal_array_subscriptions = $c->stash('proposal_array_subscriptions') // {};
    if ($proposal_array_subscriptions->{$id}) {
        _forget_pricing_subscription($c, $_) for keys %{$proposal_array_subscriptions->{$id}{proposals}};
        # proposal_array also creates 'price' subscription for itself while obtains uuid - so delete it too
        _forget_pricing_subscription($c, $id);
        delete $proposal_array_subscriptions->{$id};
        $c->stash(proposal_array_subscriptions => $proposal_array_subscriptions);
        return [$id];
    }
    return [];
}

sub _get_proposal_array_proposal_ids {
    my $c                            = shift;
    my $ret                          = [];
    my $proposal_array_subscriptions = $c->stash('proposal_array_subscriptions') // {};
    push @$ret, keys %{$proposal_array_subscriptions->{$_}{proposals}} for (keys %$proposal_array_subscriptions);
    return $ret;
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
                    unless (keys %{$pricing_channel->{$channel}}) {
                        delete $pricing_channel->{$channel};
                    }
                }
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
        Binary::WebSocketAPI::v3::Wrapper::Streamer::transaction_channel($c, 'unsubscribe', $c->stash('account_id'), 'poc')
            if $c->stash('account_id');
        $c->stash('proposal_open_contracts_subscribed' => 0) if $type eq 'proposal_open_contract';

        @$removed_ids = keys %{$pricing_channel->{price_daemon_cmd}->{$price_daemon_cmd}};
        my $proposal_array_proposal_ids = _get_proposal_array_proposal_ids($c);
        @$removed_ids = array_minus(@$removed_ids, @$proposal_array_proposal_ids);
        foreach my $uuid (@$removed_ids) {
            my $redis_channel = $pricing_channel->{uuid}->{$uuid}->{redis_channel};
            my $subchannel    = $pricing_channel->{uuid}->{$uuid}->{subchannel};
            delete $pricing_channel->{$redis_channel}{$subchannel};
            unless (keys %{$pricing_channel->{$redis_channel}}) {
                delete $pricing_channel->{$redis_channel};
            }
            delete $pricing_channel->{uuid}->{$uuid};
            delete $pricing_channel->{price_daemon_cmd}->{$price_daemon_cmd}->{$uuid};
        }
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
            my $worker = $subscription->{$channel};
            my $uuid   = $worker->uuid;
            # forget all call sends strings like forget_all: candles|tick|proposal_open_contract
            if (
                ($typeoruuid eq 'candles' and looks_like_number($ftype))
                # . 's' while we are still using ticks in this calls. backward compatibility that must be removed
                or (($ftype . 's') =~ /^$typeoruuid/)
                # this is condition for forget call where we send unique id forget: id
                or ($typeoruuid eq $uuid))

            {
                push @$removed_ids, $uuid;
                Binary::WebSocketAPI::v3::Wrapper::Streamer::feed_channel_unsubscribe($c, $fsymbol, $ftype, $req_id);
            }
        }
    }
    return $removed_ids;
}

1;
