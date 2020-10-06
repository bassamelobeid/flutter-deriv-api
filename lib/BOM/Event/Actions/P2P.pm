package BOM::Event::Actions::P2P;

use strict;
use warnings;

no indirect;

use feature 'state';

=head1 NAME

BOM::Event::Actions::P2P - deal with P2P events

=head1 DESCRIPTION

The peer-to-peer cashier feature provides a way for buyers and sellers to transfer
funds using whichever methods they are able to negotiate between themselves directly.

=cut

use Log::Any qw($log);

use BOM::Database::ClientDB;
use JSON::MaybeUTF8 qw(encode_json_utf8);
use BOM::Config::Redis;
use BOM::Config::Runtime;
use BOM::Platform::Context qw(request);
use BOM::Platform::Event::Emitter;
use BOM::User::Utility;
use BOM::Platform::Email qw(send_email);
use BOM::User::Client;
use BOM::Event::Services::Track;

use Syntax::Keyword::Try;
use Format::Util::Numbers qw/financialrounding formatnumber/;
use Date::Utility;
use DataDog::DogStatsd::Helper qw(stats_timing stats_inc);
use BOM::Event::Utility qw(exception_logged);

#TODO: Put here id for special bom-event application
# May be better to move it to config rather than keep it here.
use constant {
    DEFAULT_SOURCE => 5,
    DEFAULT_STAFF  => 'AUTOEXPIRY',
};

=head2 advertiser_created

Advertiser was created.
Dummy handler for now.

=cut

sub advertiser_created {
    return 1;
}

=head2 advertiser_updated

An update to an advertiser - different name, for example - may
be relevant to anyone with an active order.

=cut

sub advertiser_updated {
    my $data = shift;

    unless ($data->{client_loginid}) {
        $log->info('Fail to process advertiser_updated: Invalid event data', $data);
        return 0;
    }

    my $client = BOM::User::Client->new({loginid => $data->{client_loginid}});

    my $details = $client->p2p_advertiser_info or return 0;

    # will be removed in websocket
    $details->{client_loginid} = $client->loginid;
    my $redis     = BOM::Config::Redis->redis_p2p_write();
    my $redis_key = _get_advertiser_channel_name($client);
    $redis->publish($redis_key, encode_json_utf8($details));

    return 1;
}

=head2 advert_created

An advertiser has created a new advert. This is always triggered
even if the advertiser has marked themselves as inactive, so
it's important to check advertiser status before sending
any client notifications here.

=cut

sub advert_created {
    return 1;
}

=head2 advert_updated

An existing advert has been updated. Either that's because the
an order has closed (confirmed/cancelled), or the details have
changed.

=cut

sub advert_updated {

    return 1;
}

=head2 order_created

An order has been created against an advert.

It returns a Future object.

=cut

sub order_created {
    my $data = shift;
    my @args = qw(client_loginid order_id);

    if (grep { !$data->{$_} } @args) {
        $log->info('Fail to process order_created: Invalid event data', $data);
        return 0;
    }

    $data->{order_event} = 'created';

    # Currently we have the same processing for this events
    # but maybe in future we will want to separete them
    return order_updated($data);
}

=head2 order_updated

An existing order has been updated. Typically these would be status updates.

It returns a Future object.

=cut

sub order_updated {
    my $data = shift;
    my @args = qw(client_loginid order_id);

    if (grep { !$data->{$_} } @args) {
        $log->info('Fail to process order_updated: Invalid event data', $data);
        return 0;
    }

    my ($loginid, $order_id, $order_event) = @{$data}{@args, 'order_event'};
    $order_event //= 'missing';

    my $client = BOM::User::Client->new({loginid => $loginid});

    my $order          = $client->_p2p_orders(id => $order_id)->[0];
    my $order_response = $client->_order_details([$order])->[0];

    my $redis     = BOM::Config::Redis->redis_p2p_write();
    my $redis_key = _get_order_channel_name($client);
    my $parties;
    for my $client_type (qw(advertiser_loginid client_loginid)) {
        my $cur_client = $client;
        if ($order->{$client_type} ne $client->loginid) {
            $cur_client = BOM::User::Client->new({loginid => $order->{$client_type}});
        }

        # set $parties->{advertiser} and $parties->{client}
        $parties->{$client_type =~ s/_loginid//r} = $cur_client;

        $order_response = $cur_client->_order_details([$order])->[0];
        $order_response->{$client_type} = $order->{$client_type};
        $redis->publish($redis_key, encode_json_utf8($order_response));
    }

    stats_inc('p2p.order.status.updated.count', {tags => ["status:$order->{status}"]});

    return _track_p2p_order_event(
        loginid       => $loginid,
        order         => $order,
        order_details => $order_response,
        order_event   => $order_event,
        parties       => $parties,
    );
}

=head2 timeout_refund

When an order hangs for 30 days with no dispute raised. The funds should be moved back to seller.
An email regarding this refund should be sent to both parties.

It takes a hash argument as:

=over 4

=item * C<order_id>: the id of the order

=item * C<client_loginid>: the client loginid who placed the order

=back

Returns, C<1> on success, C<0> otherwise.

=cut

sub timeout_refund {
    my $data = shift;

    my ($client, $updated_order);
    try {
        $data->{$_} or die "Missing required attribute $_" for qw(client_loginid order_id);
        my ($loginid, $order_id) = @{$data}{qw(client_loginid order_id)};

        $client = BOM::User::Client->new({loginid => $loginid});

        $updated_order = $client->p2p_timeout_refund(
            id     => $order_id,
            source => $data->{source} // DEFAULT_SOURCE,
            staff  => $data->{staff} // DEFAULT_STAFF,
        );
        return 1 if $updated_order;
    } catch {
        my $err = $@;
        $log->info('Fail to process order_refund: ' . $err, $data);
        exception_logged();
    }

    return 0;
}

=head2 order_expired

An order reached our predefined timeout without being confirmed by both sides or
cancelled by the client.

=cut

sub order_expired {
    my $data = shift;

    if ($data->{expiry_started}) {
        stats_timing('p2p.order.expiry.delay', (1000 * Time::HiRes::tv_interval($data->{expiry_started})));
    }

    BOM::Config::Runtime->instance->app_config->check_for_update;

    my ($client, $updated_order);
    try {
        $data->{$_} or die "Missing required attribute $_" for qw(client_loginid order_id);
        my ($loginid, $order_id) = @{$data}{qw(client_loginid order_id)};

        $client = BOM::User::Client->new({loginid => $loginid});

        $updated_order = $client->p2p_expire_order(
            id     => $order_id,
            source => $data->{source} // DEFAULT_SOURCE,
            staff  => $data->{staff} // DEFAULT_STAFF,
        );
        return 1 if $updated_order;
    } catch {
        my $err = $@;
        $log->info('Fail to process order_expired: ' . $err, $data);
        exception_logged();
    }

    return 0;
}

=head2 _track_p2p_order_event

Emits p2p order events to Segment for tracking. It takes the following list of named arguments:

=over 4

=item * C<loginid> - required. representing the client who has fired the event.

=item * C<order> - required. A hashref containing order raw data.

=item * C<order_details> - required. A hashref containing processed order details.

=item * C<order_event> - required. Order event name (like B<created>, B<buyer-confirmed>, etc).

=item * C<parties> - required. A hashref containing parties involved in the p2p order, namely the advertiser, client, buyer and seller.

=back

It returns a Future object.

=cut

sub _track_p2p_order_event {
    my %args = @_;
    my ($loginid, $order, $order_details, $order_event, $parties) = @args{qw(loginid order order_details order_event parties)};

    # set seller/buyer objects and nicknames based on order type
    my ($seller, $buyer) = ($order->{type} eq 'sell') ? qw(client advertiser) : qw(advertiser client);
    @{$parties}{qw(seller buyer)}                        = @{$parties}{$seller, $buyer};
    @{$parties}{qw(seller_nickname buyer_nickname)}      = @{$order}{"${seller}_name", "${buyer}_name"};
    @{$parties}{qw(advertiser_nickname client_nickname)} = @{$order}{qw(advertiser_name client_name)};

    # buyer and seller confirmations are two different events in event tracking
    if ($order_event eq 'confirmed') {
        $order_event = ($loginid eq $parties->{buyer}->loginid) ? 'buyer_has_paid' : 'seller_has_released';
    }

    my $method = BOM::Event::Services::Track->can("p2p_order_${order_event}");

    # There are order events that are not tracked yet. Let's skip them.
    return Future->done(1) unless ($method);

    return $method->(
        loginid => $loginid,
        order   => $order_details,
        parties => $parties,
    );
}

sub _get_order_channel_name {
    my $client = shift;

    return join q{::} => map { uc($_) } ("P2P::ORDER::NOTIFICATION", $client->broker, $client->residence, $client->currency,);
}

sub _get_advertiser_channel_name {
    my $client = shift;

    return join q{::} => map { uc($_) } ("P2P::ADVERTISER::NOTIFICATION", $client->broker);
}

1;
