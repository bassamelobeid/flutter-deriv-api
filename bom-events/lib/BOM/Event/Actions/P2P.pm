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
use BOM::Platform::Context qw(localize request);
use BOM::Platform::Event::Emitter;
use BOM::User::Utility   qw(p2p_rate_rounding);
use BOM::Platform::Email qw(send_email);
use BOM::User::Client;
use BOM::Event::Services::Track;
use BOM::Event::Actions::Common;

use Syntax::Keyword::Try;
use Format::Util::Numbers qw/financialrounding formatnumber/;
use Date::Utility;
use DataDog::DogStatsd::Helper qw(stats_timing stats_inc);
use BOM::Event::Utility        qw(exception_logged);
use List::Util                 qw(any first uniq none);
use Future::AsyncAwait;
use Template::AutoFilter;
use Encode;
use Array::Utils qw(intersect);
use Time::HiRes  qw(gettimeofday tv_interval);

#TODO: Put here id for special bom-event application
# May be better to move it to config rather than keep it here.
use constant {
    DEFAULT_SOURCE       => 5,
    DEFAULT_STAFF        => 'AUTOEXPIRY',
    P2P_LOCAL_CURRENCIES => 'P2P::LOCAL_CURRENCIES',
    P2P_ORDER_STATUS     => {
        active => [qw(pending buyer-confirmed timed-out disputed)],
        final  => [qw(completed cancelled refunded dispute-refunded dispute-completed)],
    }};

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
Will publish responses tailored for each subscriber client.

Takes one of the following named parameters in a hashref:

=over 4

=item * client: client object

=item * client_loginid: client loginid, only used if client is not passed

=back

=cut

sub advertiser_updated {
    my $data = shift;

    my $advertiser_loginid = $data->{client} ? $data->{client}->loginid : $data->{client_loginid};

    unless ($advertiser_loginid) {
        $log->infof('Fail to process advertiser_updated: Invalid event data: %s', $data);
        return 0;
    }

    my $redis = BOM::Config::Redis->redis_p2p_write();
    # channel format is P2P::ADVERTISER::NOTIFICATION::$advertiser_loginid::$subscriber_loginid
    my $channels = $redis->pubsub('channels', "P2P::ADVERTISER::NOTIFICATION::${advertiser_loginid}::*");

    for my $channel (@$channels) {
        my ($subscriber_loginid) = $channel =~ /::(\w+?)$/;

        next if $data->{self_only} and $subscriber_loginid ne $advertiser_loginid;
        my $subscriber_client =
            ($data->{client} and $subscriber_loginid eq $advertiser_loginid)
            ? $data->{client}
            : BOM::User::Client->new({loginid => $subscriber_loginid});

        next if $subscriber_client->p2p_is_advertiser_blocked;

        my $advertiser = $subscriber_client->_p2p_advertisers(loginid => $advertiser_loginid)->[0] // next;
        my $details    = $subscriber_client->_advertiser_details($advertiser);
        $redis->publish($channel, encode_json_utf8($details));
    }

    return 1;
}

=head2 advertiser_online_status

This event is responsible if the online status for advertiser will 
publish the newest status to advertiser and order channels.

=over 4

=item * client_loginid: client loginid

=back

=cut

sub advertiser_online_status {
    my $data               = shift;
    my $advertiser_loginid = $data->{client_loginid};
    my $client             = BOM::User::Client->new({loginid => $advertiser_loginid});
    my $advertiser         = $client->_p2p_advertisers(loginid => $client->loginid)->[0];
    my $advertiser_id      = $advertiser->{id};

    return 0 unless $advertiser_loginid or $advertiser_id;

    advertiser_updated({client => $client});

    _publish_orders_to_channels({
        loginid           => $advertiser_loginid,
        client            => $client,
        online_advertiser => 1,
        advertiser_id     => $advertiser_id
    });

    return 1;
}

=head2 settings_updated

One of the fields in p2p_dynamic_settings.cgi|p2p_advert_rates_manage.cgi in backoffice has been
updated or new exchange rate published for p2p currency with floating rate enabled.
We will publish p2p_settings response with updated fields to redis channel: "NOTIFY::P2P_SETTINGS::<country code>"
If P2P dynamic settings was updated, response will be sent to all active subscribers.
If p2p_advert_rates_manage.cgi or exchange rate was updated, response will be sent to P2P subscribers from specific countries only.

Takes the following named parameters:

=over 4

=item * C<affected_countries>: arrayref containing specific country codes (optional)

=back

=cut

sub settings_updated {
    my $data                 = shift;
    my $redis                = BOM::Config::Redis->redis_p2p_write();
    my @countries            = map { lc((split /::/, $_)[2]) } $redis->pubsub('channels', "NOTIFY::P2P_SETTINGS::*")->@*;
    my $app_config           = BOM::Config::Runtime->instance->app_config;
    my @restricted_countries = $app_config->payments->p2p->restricted_countries->@*;

    $app_config->check_for_update(1) if @countries;
    # We only need to get updated app config if we have at least one active subscription to p2p_settings endpoint

    for my $country (@countries) {
        next if any { $_ eq $country } @restricted_countries;
        next if $data->{affected_countries} && none { $_ eq $country } $data->{affected_countries}->@*;
        my $result = BOM::User::Utility::get_p2p_settings(%$data, country => $country);
        $redis->publish("NOTIFY::P2P_SETTINGS::${\uc($country)}", encode_json_utf8($result));
    }

    return 1;
}

=head2 advert_created

An advert has been created.

=cut

sub advert_created {
    my $data = shift;

    return BOM::Event::Services::Track::p2p_advert_created($data);
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

async sub order_updated {
    my $data = shift;
    my @args = qw(client_loginid order_id);

    if (grep { !$data->{$_} } @args) {
        $log->info('Fail to process order_updated: Invalid event data', $data);
        return 0;
    }

    my ($loginid, $order_id, $order_event) = @{$data}{@args, 'order_event'};
    my $client         = BOM::User::Client->new({loginid => $loginid});
    my $order          = $client->_p2p_orders(id => $order_id)->[0];
    my $order_response = $client->_order_details([$order])->[0];
    $order_event //= 'missing';

    _publish_orders_to_channels({
            loginid   => $loginid,
            client    => $client,
            self_only => $data->{self_only},
            order_id  => $order_id,
            orders    => [$order]});

    my $parties = {
        advertiser => $order_response->{advertiser_details}->{loginid},
        client     => $order_response->{client_details}->{loginid}};

    stats_inc('p2p.order.status.updated.count', {tags => ["status:$order->{status}"]});

    BOM::Platform::Event::Emitter::emit(
        'p2p_order_updated_handled',
        {
            loginid       => $loginid,
            order         => $order,
            order_details => $order_response,
            order_event   => $order_event,
            parties       => $parties,
        });

    _freeze_chat_channel($order->{chat_channel_url})
        if $order->{chat_channel_url} and any { $order->{status} eq $_ } qw/completed cancelled refunded dispute-refunded dispute-completed/;

    return 1;

}

=head2 dispute_expired

When a disputed order is not resolved for 24 hours (default but configurable) 
a ticket should be raised.

It takes a hash argument as:

=over 4

=item * C<order_id>: the id of the order

=item * C<broker_code>: the broker code where this order operates

=item * C<timestamp>: the dispute timestamp

=back

Returns, C<1> on success, C<0> otherwise.

=cut

sub dispute_expired {
    my $data        = shift;
    my $order_id    = $data->{order_id};
    my $broker_code = $data->{broker_code};
    my $timestamp   = $data->{timestamp};
    return 0 if not $order_id or not $broker_code;

    my $app_config = BOM::Config::Runtime->instance->app_config;

    my $db = BOM::Database::ClientDB->new({broker_code => $broker_code})->db->dbh;
    # Recover the order, ensure is disputed
    my ($order) =
        $db->selectall_arrayref('SELECT * FROM p2p.order_list(?, NULL, NULL, ?::p2p.order_status[], 1, NULL)', {Slice => {}}, $order_id, '{disputed}')
        ->@*;

    if ($order) {
        my $brand              = request()->brand;
        my $client_loginid     = $order->{client_loginid};
        my $advertiser_loginid = $order->{advertiser_loginid};
        my $disputer_loginid   = $order->{disputer_loginid};
        my $reason             = $order->{dispute_reason};
        my $amount             = $order->{amount};
        my $currency           = $order->{local_currency};
        my $buyer              = $client_loginid;
        my $seller             = $advertiser_loginid;
        $buyer  = $advertiser_loginid if $order->{type} eq 'sell';
        $seller = $client_loginid     if $order->{type} eq 'sell';
        my $disputed_at = Date::Utility->new($timestamp)->datetime_ddmmmyy_hhmmss_TZ;

        send_email({
                from                  => $brand->emails('no-reply'),
                to                    => $app_config->payments->p2p->email_to,
                subject               => "P2P dispute expired for Order ID: $order_id",
                email_content_is_html => 1,
                message               => [
                    '<p>A P2P order has been disputed for a while without resolution. Here are the details:<p>',
                    '<ul>',
                    "<li><b>Buyer Loginid:</b> $buyer</li>",
                    "<li><b>Seller Loginid:</b> $seller</li>",
                    "<li><b>Raised by:</b> $disputer_loginid</li>",
                    "<li><b>Reason:</b> $reason</li>",
                    "<li><b>Order ID:</b> $order_id</li>",
                    "<li><b>Amount:</b> $amount</li>",
                    "<li><b>Currency:</b> $currency</li>",
                    "<li><b>Dispute raised time:</b> $disputed_at</li>",
                    '</ul>',
                ],
            });

        return 1;
    }

    return 0;
}

=head2 order_expired

Process an order expiry event from p2p_daemon - usually at 2 hours and 30 days.

It takes a hash argument as:

=over 4

=item * C<order_id>: the id of the order

=item * C<client_loginid>: the client loginid who placed the order

=back

Returns, C<1> on success, C<0> otherwise.

=cut

sub order_expired {
    my $data = shift;

    if ($data->{expiry_started}) {
        stats_timing('p2p.order.expiry.delay', (1000 * Time::HiRes::tv_interval($data->{expiry_started})));
    }

    try {
        $data->{$_} or die "Missing required attribute $_" for qw(client_loginid order_id);
        my ($loginid, $order_id) = @{$data}{qw(client_loginid order_id)};
        my $client = BOM::User::Client->new({loginid => $loginid});

        my $status = $client->p2p_expire_order(
            id     => $order_id,
            source => $data->{source} // DEFAULT_SOURCE,
            staff  => $data->{staff}  // DEFAULT_STAFF,
        );

        return $status ? 1 : 0;
    } catch ($err) {
        $log->info('Fail to process order_expired: ' . $err, $data);
        exception_logged();
    }

    return 0;
}

=head2 timeout_refund

When an order hangs for 30 days with no dispute raised. The funds should be moved back to seller.
An email regarding this refund should be sent to both parties.

This is currently just a wrapper around order_expired().

=cut

sub timeout_refund {
    return order_expired(@_);
}

=head2 chat_received

A chat message received from sendbird webhook, note the webhook already checks for data validity and sanity, at this
point we just perform the database insert and call it a day.

It takes the following named params:

=over 4

=item C<message_id> the message id

=item C<created_at> message timestamp

=item C<user_id> sendbird chat user id

=item C<channel> sendbird chat channel

=item C<type> sendbird message type, FILE or MESG

=item C<message> sendbird chat content when the message type is MESG

=item C<url> url to file when the message type is FILE

=back

Return, the database insert result or false on exception.

=cut

sub chat_received {
    my $data      = shift;
    my @values    = @{$data}{qw(message_id created_at user_id channel type message url)};
    my $collector = BOM::Database::ClientDB->new({broker_code => 'FOG'})->db->dbic;

    return $collector->run(
        fixup => sub {
            $_->do(q{SELECT * FROM data_collection.p2p_chat_message_add(?::BIGINT,?::BIGINT,?::TEXT,?::TEXT,?::TEXT,?::TEXT,?::TEXT)},
                undef, @values);
        });
}

=head2 archived_ad

Triggered when p2p maintenance scripts archives an advert.

The side effects of this events are:

=over 4

=item * Send event to customer.io for email sending.

=back

It takes the following named params:

=over 4

=item * C<id> id of the archived ad.

=back

Returns C<1> on success, dies otherwise.

=cut

sub archived_ad {
    my $data    = shift;
    my $loginid = $data->{advertiser_loginid}                   || die 'Missing advertiser loginid';
    my $client  = BOM::User::Client->new({loginid => $loginid}) || die 'Client not found';
    my $ads     = $data->{archived_ads} // [];

    die 'Empty ads' unless scalar $ads->@*;

    my @deactivated_ads = map { $client->_p2p_adverts(id => $_, limit => 1)->[0] } $ads->@*;
    $_->{effective_rate} = p2p_rate_rounding($_->{effective_rate}, display => 1) foreach @deactivated_ads;

    return BOM::Event::Services::Track::p2p_archived_ad({
        client  => $client,
        adverts => \@deactivated_ads,
    });
}

=head2 p2p_adverts_updated

Publish p2p_advert_info updates to subscribers.

=over 4

=item * C<advertiser_id> advertiser id of updated adverts.

=item * C<channels> redis channels of current subscribers (optional).

=back

=cut

sub p2p_adverts_updated {
    my $data = shift;
    my ($channels, $advertiser_id) = @$data{qw/channels advertiser_id/};

    my $redis = BOM::Config::Redis->redis_p2p_write;
    $channels //= $redis->pubsub('channels', 'P2P::ADVERT::' . $advertiser_id . '::*');
    return unless $channels and @$channels;

    my ($adverts, $client_channels);
    for my $channel (@$channels) {
        my ($loginid, $advert_id) = $channel =~ /P2P::ADVERT::.+?::.+?::(.+?)::(.+?)$/;
        my $client = BOM::User::Client->new({loginid => $loginid});
        if ($advert_id eq 'ALL') {
            $adverts->{$loginid}{$advert_id} = $client->p2p_advertiser_adverts;
        } else {
            $adverts->{$loginid}{$advert_id} = [
                $client->p2p_advert_info(id => $advert_id) // {
                    id      => $advert_id,
                    deleted => 1
                }];
        }
        $client_channels->{$loginid}{$advert_id} = $channel;
    }

    my $updates = BOM::User::Utility::p2p_on_advert_view($advertiser_id, $adverts);
    return 1 unless $updates;

    for my $loginid (keys %$updates) {
        for my $advert_id (keys $updates->{$loginid}->%*) {
            for my $item ($updates->{$loginid}{$advert_id}->@*) {
                $redis->publish($client_channels->{$loginid}{$advert_id}, encode_json_utf8($item));
            }
        }
    }

    return 1;
}

=head2 p2p_advertiser_approval_changed

Handle event fired from backoffice, and called from bom-events code after a client
becomes age verified.

=over 4

=item * C <client> client object .

=back

=cut

sub p2p_advertiser_approval_changed {
    my $data = shift;

    my $client = $data->{client} // BOM::User::Client->new({loginid => $data->{client_loginid}});

    # to push FE notification when advertiser becomes approved/unapproved via db trigger
    advertiser_updated({client => $client});

    return unless ($client->status->reason('allow_document_upload') // '') eq 'P2P_ADVERTISER_CREATED';
    return unless $client->_p2p_advertiser_cached and $client->_p2p_advertiser_cached->{is_approved};

    my $brand = request->brand;

    my $data_tt = {
        l           => \&localize,
        contact_url => $brand->contact_url,
    };
    my $tt = Template->new(ABSOLUTE => 1);

    try {
        $tt->process(BOM::Event::Actions::Common::TEMPLATE_PREFIX_PATH() . 'age_verified_p2p.html.tt', $data_tt, \my $html);

        die "Template error: @{[$tt->error]}" if $tt->error;
        send_email({
                from          => $brand->emails('no-reply'),
                to            => $client->email,
                subject       => localize('You can now use Deriv P2P'),
                message       => [$html],
                template_args => {
                    name  => $client->first_name,
                    title => localize('You can now use Deriv P2P'),
                },
                use_email_template    => 1,
                email_content_is_html => 1,
                skip_text2html        => 1,
            });
    } catch ($e) {
        $log->warn($e);
    }

    BOM::Platform::Event::Emitter::emit('p2p_advertiser_approved', {loginid => $client->loginid});
}

=head2 p2p_advert_orders_updated

An advert has been updated.
At least one the the following advert fields have been updated: (description|payment_method_names|payment_method_ids).
If that advert has active orders, updated order info is sent to order creator if he has active subscription.

=over 4

=item * C <loginid> client loginid

=back

=cut

sub p2p_advert_orders_updated {
    my $data   = shift;
    my $client = BOM::User::Client->new({loginid => $data->{client_loginid}});
    my $orders = $client->_p2p_orders(
        advert_id => $data->{advert_id},
        active    => 1,
    );

    _publish_orders_to_channels({
        advert_updated => 1,
        orders         => $orders
    });

    return 1;
}

=head2 order_chat_create

An order chat has been created against an order.

It returns a Future object.

=cut

sub order_chat_create {
    my $data = shift;
    my @args = qw(client_loginid order_id);

    if (grep { !$data->{$_} } @args) {
        $log->info('Fail to process order_updated: Invalid event data', $data);
        return 0;
    }

    my ($loginid, $order_id) = @{$data}{@args};
    my $client = BOM::User::Client->new({loginid => $loginid});

    try {
        $client->p2p_create_order_chat(order_id => $order_id);
    } catch ($e) {
        $log->warnf("Failed to create  p2p order chat: %s", $e);
        return 0;
    }

    return 1;
}

=head2 advertiser_cancel_at_fault

An order has been manually cancelled or expired without paying.

=cut

sub advertiser_cancel_at_fault {
    my $data = shift;
    return BOM::Event::Services::Track::p2p_advertiser_cancel_at_fault($data);
}

=head2 advertiser_temp_banned

An advertiser has temporarily banned for too many manual cancels or creating too many orders which expired.

=cut

sub advertiser_temp_banned {
    my $data = shift;
    return BOM::Event::Services::Track::p2p_advertiser_temp_banned($data);
}

=head2 update_local_currencies

Updates redis key for available local currencies.
Called by p2p daemon every minute.

=cut

sub update_local_currencies {
    my $start_tv       = [gettimeofday];
    my %new_currencies = ();
    my $redis          = BOM::Config::Redis->redis_p2p_write();

    # if we ever support multiple brokers in P2P, this will need reworking
    for my $broker (map { $_->broker_codes->@* } grep { $_->p2p_available } LandingCompany::Registry::get_all) {
        my $clientdb = BOM::Database::ClientDB->new({broker_code => uc $broker, operation => 'backoffice_replica'});
        my @currency = $clientdb->db->dbic->run(
            fixup => sub {
                $_->selectcol_arrayref('SELECT * FROM p2p.active_local_currencies()');
            })->@*;
        @new_currencies{@currency} = () if @currency;
    }
    delete $new_currencies{'AAD'};
    my $new_currencies = join ',', sort keys %new_currencies;

    # check if there is change in local currencies
    if ($new_currencies ne ($redis->get(P2P_LOCAL_CURRENCIES) // '')) {
        BOM::Config::Redis->redis_p2p_write->set(P2P_LOCAL_CURRENCIES, $new_currencies);
        BOM::Platform::Event::Emitter::emit(p2p_settings_updated => {});
        stats_timing('p2p.update_local_currency.processing_time', 1000 * tv_interval($start_tv));
    }

}

=head2 track_p2p_order_event

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

sub track_p2p_order_event {
    my $args = shift;

    my ($loginid, $order, $order_details, $order_event, $parties) = $args->@{qw(loginid order order_details order_event parties)};

    # set seller/buyer objects and nicknames based on order type
    my ($seller, $buyer) = ($order->{type} eq 'sell') ? qw(client advertiser) : qw(advertiser client);
    $parties->{seller} = $parties->{$seller} ? BOM::User::Client->new({loginid => $parties->{$seller}}) : undef;
    $parties->{buyer}  = $parties->{$buyer}  ? BOM::User::Client->new({loginid => $parties->{$buyer}})  : undef;

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
        order   => $order_details,
        parties => $parties,
    );
}

sub _get_advertiser_channel_name {
    my $client = shift;

    return join q{::} => map { uc($_) } ("P2P::ADVERTISER::NOTIFICATION", $client->broker);
}

=head2 _freeze_chat_channel

Freezes a sendbird chat channel, which prevents users sending messages.

=over 4

=item * C<channel> - required. Sendbird chat channel url.

=back

=cut

sub _freeze_chat_channel {
    my $channel = shift;
    return BOM::User::Utility::sendbird_api()->view_group_chat(channel_url => $channel)->set_freeze(1);
}

=head2 _validate_order_for_channel

returns true if order is match for channel

=over 4

=item * C<channel> - required. Order Redis channel.

=item * C<order> - required. A hashref containing order raw data.

=back

=cut

sub _validate_order_for_channel {
    my $ch_params = shift;
    my $order     = shift;
    if ((
               $ch_params->{advertiser_id} == $order->{client_id}
            || $ch_params->{advertiser_id} == $order->{advertiser_id}
            || $ch_params->{advertiser_id} == -1    #this condition(line) after release can be removed.
        )
        && ($ch_params->{advert_id} == $order->{advert_id} || $ch_params->{advert_id} == -1)
        && ($ch_params->{order_id} == $order->{id}         || $ch_params->{order_id} == -1)
        && (   ($ch_params->{active} == 1 && any { $order->{status} eq $_ } P2P_ORDER_STATUS->{active}->@*)
            || ($ch_params->{active} == 0 && any { $order->{status} eq $_ } P2P_ORDER_STATUS->{final}->@*)
            || ($ch_params->{active} == -1)))
    {
        return 1;
    } else {
        return;
    }
}

=head2 _publish_orders_to_channels

Publish only relevant orders to only relevant channels

=over 4

=item * C<client> - optional. representing the client who has fired the event.

=item * C<loginid> - optional. loginid belongs to event emitter.

=item * C<self_only> - optional. indicates whether for event emmiter or not.

=item * C<online_advertiser> - optional. indicates whether for only online advertisers or not.

=item * C<advertiser_id> - optional. advertiser id belongs to event emitter.

=item * C<orders> - required. An arrayref containing orders raw data.

=item * C<order_id> - optional. Indicates the order id for single order update.

=back

=cut

sub _publish_orders_to_channels {
    my $args     = shift;
    my %clients  = $args->{loginid} ? ($args->{loginid} => $args->{client} // BOM::User::Client->new({loginid => $args->{loginid}})) : ();
    my $redis    = BOM::Config::Redis->redis_p2p_write();
    my $members  = $args->{online_advertiser} && $args->{advertiser_id} ? $redis->smembers('P2P::ORDER::PARTIES::' . $args->{advertiser_id}) : undef;
    my $channels = $redis->pubsub('channels', "P2P::ORDER::NOTIFICATION::CR::*");
    my $parsed_channels;

    #Format of channel is P2P::ORDER::NOTIFICATION::BROKER_CODE::LOGINID::ADVERTISER_ID::ADVERT_ID::ORDER_ID::ACTIVE_ORDERS
    #Possible values for ADVERT_ID and ORDER_ID: -1 means all adverts/orders, any possitive number is for particular advert or order
    #Possible values for ACTIVE_ORDERS: -1 means both active and non active, 0 means non active: 1 means active orders
    foreach my $channel ($channels->@*) {
        my @params = split '::', $channel;
        push @$parsed_channels, {
            channel            => $channel,
            broker_code        => $params[3],
            subscriber_loginid => $params[4],
            advertiser_id      => $params[5] // -1,    #These -1 place holders are temporary for channels already exist during release,
            advert_id          => $params[6] // -1,    #Few days after release we should remove.
            order_id           => $params[7] // -1,
            active             => $params[8] // -1
        };
    }

    my @parsed_channels_advertisers = map { $_->{advertiser_id} } @$parsed_channels;
    return unless ($args->{online_advertiser} and intersect(@parsed_channels_advertisers, @$members)) || !$args->{online_advertiser};

    my %orders_payment_method = ();
    my $orders =
          $args->{online_advertiser} && $args->{advertiser_id}
        ? $clients{$args->{loginid}}->_p2p_orders(loginid => $args->{loginid})
        : $args->{orders};

    foreach my $channel (@$parsed_channels) {
        my $advertiser_id = $channel->{advertiser_id};
        my $loginid       = $channel->{subscriber_loginid};
        my $order_id      = $channel->{order_id};
        next unless not $args->{online_advertiser} or any { $advertiser_id == $_ } $members->@*;
        foreach my $order ($orders->@*) {
            next if ((($args->{self_only}) && ($loginid ne $args->{loginid})) || (not _validate_order_for_channel($channel, $order)));
            next if $args->{advert_updated} && ($order_id ne $order->{id} || $loginid ne $order->{client_loginid});
            my $loginid = $loginid eq $order->{client_loginid} ? $order->{client_loginid} : $order->{advertiser_loginid};
            $clients{$loginid} //= BOM::User::Client->new({loginid => $loginid});
            $orders_payment_method{$order->{id}} //= $clients{$loginid}->_p2p_order_payment_method_details($order);
            $order->{payment_method_details} = $orders_payment_method{$order->{id}};
            $redis->publish($channel->{channel}, encode_json_utf8($clients{$loginid}->_order_details([$order])->[0]));
        }
    }
}

1;
