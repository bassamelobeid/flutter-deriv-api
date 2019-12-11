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

#TODO: Put here id for special bom-event application
# May be better to move it to config rather than keep it here.
use constant {
    DEFAULT_SOURCE => 5,
    DEFAULT_STAFF  => 'AUTOEXPIRY',
};

=head2 agent_created

When there's a new request to sign up as an agent,
we'd presumably want some preliminary checks and
then mark their status as C<approved> or C<active>.

Currently there's a placeholder email.

=cut

sub agent_created {
    BOM::Platform::Event::Emitter::emit(
        send_email_generic => {
            to      => 'compliance@binary.com',
            subject => 'New P2P agent registered',
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
    return 1;
}

=head2 order_updated

An existing order has been updated. Typically these would be status updates.

=cut

sub order_updated {
    return 1;
}

=head2 order_expired

An order reached our predefined timeout without being confirmed by both sides or
cancelled by the client.

We'd want to do something here - perhaps just mark the order as expired.

=cut

sub order_expired {
    my $data = shift;

    # If status was changed, handler should return new status
    state $expiration_handlers_for = {
        pending            => \&_pending_expiration,
        'client-confirmed' => \&_client_confirmed_expiration,
        cancelled          => sub { },
        completed          => sub { },
        refunded           => sub { },
        expired            => sub { },
    };

    $data->{$_} or die "Missing required attribute $_" for qw(broker_code order_id);

    my ($broker_code, $order_id, $loginid) = @{$data}{qw(broker_code order_id loginid)};

    my $client = BOM::User::Client->new({loginid => $loginid});
    my $client_dbh = $client->db->dbh;

    my $order_data = $client_dbh->selectrow_hashref(
        'SELECT id, status, client_confirmed, offer_currency currency FROM p2p.order_list(?,?,?,?)',
        undef, $order_id, (undef) x 3,
    );

    die "Order $order_id isn't found" unless $order_data;

    my $status = $order_data->{status};
    die "Unexpected status $status for order $order_id" unless $expiration_handlers_for->{$status};

    my $param = {
        broker_code => $broker_code,
        source      => $data->{source} // DEFAULT_SOURCE,
        staff       => $data->{staff} // DEFAULT_STAFF,
    };
    my $new_status = $expiration_handlers_for->{$status}->($client, $order_data, $param);

    return 1 unless $new_status;

    my $redis = BOM::Config::RedisReplicated->redis_p2p_write();
    $redis->publish(
        'P2P::ORDER::NOTIFICATION::' . $order_id,
        encode_json_utf8({
                order_id   => $order_id,
                event      => 'status_changed',
                event_data => {
                    old_status => $status,
                    new_status => $new_status,
                },
            }
        ),
    );

    return 1;
}

sub _pending_expiration {
    my ($client, $order_data, $param) = @_;

    my $escrow_account = $client->p2p_escrow;

    die "No Escrow account for broker $param->{broker_code} with currency $order_data->{currency}" unless $escrow_account;

    my $client_dbh = $client->db->dbh;
    $client_dbh->selectrow_hashref('SELECT * FROM  p2p.order_cancel(?, ?, ?, ?)',
        undef, $order_data->{id}, $escrow_account->loginid, $param->{source}, $param->{staff});

    return 'cancelled';
}

sub _client_confirmed_expiration {
    my ($client, $order_data, $param) = @_;

    my $client_dbh = $client->db->dbh;
    $client_dbh->do('SELECT * FROM p2p.order_update(?, ?)', undef, $order_data->{id}, 'expired');

    return 'expired';
}

1;
