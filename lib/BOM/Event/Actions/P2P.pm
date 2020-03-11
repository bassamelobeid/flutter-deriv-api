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
use Syntax::Keyword::Try;
use Format::Util::Numbers qw/financialrounding formatnumber/;
use Date::Utility;
use DataDog::DogStatsd::Helper qw(stats_timing stats_inc);

#TODO: Put here id for special bom-event application
# May be better to move it to config rather than keep it here.
use constant {
    DEFAULT_SOURCE => 5,
    DEFAULT_STAFF  => 'AUTOEXPIRY',
};

=head2 advertiser_created

When there's a new request to sign up as an advertiser,
we'd presumably want some preliminary checks and
then mark their status as C<approved> or C<active>.

Currently there's a placeholder email.

=cut

sub advertiser_created {
    my $data = shift;

    my @args = qw(client_loginid name contact_info default_advert_description payment_info);

    if (grep { !defined $data->{$_} } @args) {
        $log->info('Fail to procces advertiser_created: Invalid event data', $data);
        return 0;
    }

    my $email_to = BOM::Config::Runtime->instance->app_config->payments->p2p->email_to;

    return 1 unless $email_to;

    send_email({
        from    => '<no-reply@binary.com>',
        to      => $email_to,
        subject => 'New P2P advertiser registered',
        message => ['New P2P advertiser registered.', 'Advertiser information:', map { $_ . ': ' . ($data->{$_} || '<none>') } @args,],
    });

    return 1;
}

=head2 advertiser_updated

An update to an advertiser - different name, for example - may
be relevant to anyone with an active order.

=cut

sub advertiser_updated {
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

=cut

sub order_created {
    my $data = shift;
    my @args = qw(client_loginid order_id);

    if (grep { !$data->{$_} } @args) {
        $log->info('Fail to procces order_created: Invalid event data', $data);
        return 0;
    }

    # Currently we have the same processing for this events
    # but maybe in future we will want to separete them
    return order_updated($data);
}

=head2 order_updated

An existing order has been updated. Typically these would be status updates.

=cut

sub order_updated {
    my $data = shift;
    my @args = qw(client_loginid order_id);

    if (grep { !$data->{$_} } @args) {
        $log->info('Fail to procces order_updated: Invalid event data', $data);
        return 0;
    }
    my ($loginid, $order_id) = @{$data}{@args};

    my $client = BOM::User::Client->new({loginid => $loginid});

    my $order = $client->_p2p_orders(id => $order_id)->[0];
    my $order_response = $client->_order_details([$order])->[0];

    my $redis     = BOM::Config::Redis->redis_p2p_write();
    my $redis_key = _get_order_channel_name($client);
    for my $client_type (qw(advertiser_loginid client_loginid)) {
        my $cur_client = $client;
        if ($order->{$client_type} ne $client->loginid) {
            $cur_client = BOM::User::Client->new({loginid => $order->{$client_type}});
        }

        $order_response = $cur_client->_order_details([$order])->[0];
        $order_response->{$client_type} = $order->{$client_type};
        $redis->publish($redis_key, encode_json_utf8($order_response));
    }

    stats_inc('p2p.order.status.updated.count', {tags => ["status:$order->{status}"]});

    return 1;
}

=head2 order_expired

An order reached our predefined timeout without being confirmed by both sides or
cancelled by the client.

=cut

sub order_expired {
    my $data = shift;

    if ($data->{expiry_started}) {
        stats_timing('p1p.order.expiry.delay', (1000 * Time::HiRes::tv_interval($data->{expiry_started})));
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
    }
    catch {
        my $err = $@;
        $log->info('Fail to procces order_expired: ' . $err, $data);
    }

    return 0 unless $updated_order;

    stats_inc('p2p.order.expired');

    BOM::Platform::Event::Emitter::emit(
        p2p_order_updated => {
            client_loginid => $client->loginid,
            order_id       => $updated_order->{id},
        });

    return 1;
}

sub _get_order_channel_name {
    my $client = shift;

    return join q{::} => map { uc($_) } ("P2P::ORDER::NOTIFICATION", $client->broker, $client->residence, $client->currency,);
}

1;
