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
use BOM::Config::RedisReplicated;
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
    DEFAULT_SOURCE       => 5,
    DEFAULT_STAFF        => 'AUTOEXPIRY',
    AGENT_PROFILE_FIELDS => [qw(agent_loginid name)],
};

=head2 agent_created

When there's a new request to sign up as an agent,
we'd presumably want some preliminary checks and
then mark their status as C<approved> or C<active>.

Currently there's a placeholder email.

=cut

sub agent_created {
    my $data = shift;

    my $agent = $data->{agent};

    if (!$agent) {
        $log->info('Fail to process agent_created, agent data was missing', $data);
        return 0;
    }

    my $email_to = BOM::Config::Runtime->instance->app_config->payments->p2p->email_to;

    return 1 unless $email_to;

    send_email({
        from    => '<no-reply@binary.com>',
        to      => $email_to,
        subject => 'New P2P agent registered',
        message => ['New P2P agent registered.', 'Agent information:', map { "$_ : " . ($agent->{$_} // '') } @{AGENT_PROFILE_FIELDS()},],
    });

    return 1;
}

=head2 agent_updated

An update to an agent - different name, for example - may
be relevant to anyone with an active order.

=cut

sub agent_updated {
    return 1;
}

=head2 offer_created

An agent has created a new offer. This is always triggered
even if the agent has marked themselves as inactive, so
it's important to check agent status before sending
any client notifications here.

=cut

sub offer_created {
    return 1;
}

=head2 offer_updated

An existing offer has been updated. Either that's because the
an order has closed (confirmed/cancelled), or the details have
changed.

=cut

sub offer_updated {

    return 1;
}

=head2 order_created

An order has been created against an offer.

=cut

sub order_created {
    my $data = shift;
    my @args = qw(client_loginid order_id);

    if (grep { !$data->{$_} } @args) {
        $log->info('Fail to procces order_created: Invalid event data', $data);
        return 0;
    }

    my ($loginid, $order_id) = @{$data}{@args};

    my $client = BOM::User::Client->new({loginid => $loginid});

    my $order = $client->p2p_order($order_id);

    my $order_response = _order_details($client, $order);

    my $redis_key = _get_order_channel_name($client);

    my $redis = BOM::Config::RedisReplicated->redis_p2p_write();
    $redis->publish($redis_key, encode_json_utf8($order_response));

    return 1;
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
    my $order = $client->p2p_order($order_id);

    my $order_response = _order_details($client, $order);

    my $redis = BOM::Config::RedisReplicated->redis_p2p_write();

    my $redis_key = _get_order_channel_name($client);
    $redis->publish($redis_key, encode_json_utf8($order_response));

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
            order_id       => $updated_order->{order_id},
        });

    return 1;
}

sub _get_order_channel_name {
    my $client = shift;

    return join q{::} => map { uc($_) } ("P2P::ORDER::NOTIFICATION", $client->broker, $client->residence, $client->currency,);
}

sub _order_details {
    my ($client, $order) = @_;

    $order->{type} = delete $order->{offer_type};
    $order->{account_currency} //= delete $order->{offer_account_currency};
    $order->{local_currency}   //= delete $order->{offer_local_currency};

    $order->{amount} = financialrounding('amount', $order->{account_currency}, $order->{order_amount});
    $order->{amount_display} = formatnumber('amount', $order->{account_currency}, $order->{order_amount});
    $order->{expiry_time}    = Date::Utility->new($order->{expire_time})->epoch;
    $order->{created_time}   = Date::Utility->new($order->{created_time})->epoch;
    $order->{rate}           = financialrounding('amount', $order->{local_currency}, $order->{offer_rate});
    $order->{rate_display}   = formatnumber('amount', $order->{local_currency}, $order->{offer_rate});
    $order->{price}          = financialrounding('amount', $order->{local_currency}, $order->{offer_rate} * $order->{order_amount});
    $order->{price_display}  = formatnumber('amount', $order->{local_currency}, $order->{offer_rate} * $order->{order_amount});
    $order->{offer_description} //= '';
    $order->{order_description} //= '';

    #DON'T REMOVE agent_loginid and client_loginid, we relay on these fields in subscriptions code
    delete @$order{qw(
            order_amount
            offer_rate
            is_expired
            client_balance
            client_confirmed
            client_trans_id
            escrow_trans_id
            offer_remaining
            expire_time
            agent_confirmed
            )};

    return $order;
}

1;
