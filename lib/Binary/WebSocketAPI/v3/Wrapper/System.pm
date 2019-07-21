package Binary::WebSocketAPI::v3::Wrapper::System;

use strict;
use warnings;

use Scalar::Util qw(looks_like_number);
use Array::Utils qw(array_minus);
use List::Util qw(any);
use Mojo::Util qw(camelize);

use Binary::WebSocketAPI::v3::Wrapper::Transaction;
use Binary::WebSocketAPI::v3::Subscription;
# TODO move it to subscription object
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
    _forget_transaction_subscription($c, 'balance');
    _forget_transaction_subscription($c, 'transaction');
    _forget_transaction_subscription($c, 'sell');          # TODO add 'buy' type here ?
    _forget_all_pricing_subscriptions($c, 'proposal_open_contract');
    # TODO I suspect this line is not correct. Is there a feed subscription with the type 'proposal_open_contract' ?
    _forget_feed_subscription($c, 'proposal_open_contract');
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
            } elsif ($type eq 'balance' or $type eq 'transaction') {
                @removed_ids{@{_forget_transaction_subscription($c, $type)}} = ();
            } elsif ($type eq 'proposal_open_contract') {
                @removed_ids{@{_forget_all_pricing_subscriptions($c, $type)}} = ();
                # proposal_open_contract sunbscription in fact creates two subscriptions:
                #   - for pricer - getting bids
                #   - and for transactions - waiting contract sell event
                # so pricer subscription will be removed by '_forget_all_pricing_subscriptions' call (and list of uuids to return will be generated)
                # and here we just removing appropriate transaction subscriptions - whose type is sell (means, tracking sell event)
                # we don't want uuid of transaction subscriptions if the type is 'proposal_open_contract'
                # TODO I guess we need add 'buy' type also
                _forget_transaction_subscription($c, 'sell');
            } elsif ($type eq 'proposal' or $type eq 'proposal_array') {
                @removed_ids{@{_forget_all_pricing_subscriptions($c, $type)}} = ();
            }
            #TODO why we check 'proposal_open_contract' here ?
            if ($type ne 'proposal_open_contract') {
                @removed_ids{@{_forget_feed_subscription($c, $type)}} = ();
            }
        }
    }
    return {
        msg_type   => 'forget_all',
        forget_all => [keys %removed_ids],
    };
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

# TODO move it into subscription object
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
    my ($c, $id) = @_;
    return 0 unless $id && ($id =~ /-/);
    return 1 if @{_forget_all_website_status($c, $id)};    # TODO use subscription object and remove this line
    return Binary::WebSocketAPI::v3::Subscription->unregister_by_uuid($c, $id) ? 1 : 0;
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
    my ($c, $type) = @_;
    my $removed_ids   = [];
    my @subscriptions = Binary::WebSocketAPI::v3::Subscription::Transaction->get_by_class($c);
    for my $subscription (@subscriptions) {
        # $subscription->type never could be 'proposal_open_contract', so we will not return any uuids related to proposal_open_contract subscriptions
        push @$removed_ids, $subscription->uuid if $type eq $subscription->type;
        $subscription->unregister
            if $type eq $subscription->type
            # $type could be 'proposal_open_contract' only in case when forget_all is called with 'proposal_open_contract' as an argument
    }
    return $removed_ids;
}

sub _forget_all_pricing_subscriptions {
    my ($c, $type) = @_;

    Binary::WebSocketAPI::v3::Wrapper::Transaction::transaction_channel($c, 'unsubscribe', $c->stash('account_id'), 'buy')
        if $c->stash('account_id');
    $c->stash('proposal_open_contracts_subscribed' => 0) if $type eq 'proposal_open_contract';

    my $class       = 'Binary::WebSocketAPI::v3::Subscription::Pricer::' . camelize($type);
    my $removed_ids = $class->unregister_class($c);
    return $removed_ids;
}

sub _forget_feed_subscription {
    my ($c, $type) = @_;
    my $removed_ids   = [];
    my @subscriptions = Binary::WebSocketAPI::v3::Subscription::Feed->get_by_class($c);
    foreach my $subscription (@subscriptions) {
        my $uuid  = $subscription->uuid;
        my $ftype = $subscription->type;
        # forget all call sends strings like forget_all: candles|tick|proposal_open_contract
        if (
            ($type eq 'candles' and looks_like_number($ftype))
            # . 's' while we are still using ticks in this calls. backward compatibility that must be removed
            or (($ftype . 's') =~ /^$type/))
        {
            push @$removed_ids, $uuid;
            $subscription->unregister;
        }
    }
    return $removed_ids;
}

1;
