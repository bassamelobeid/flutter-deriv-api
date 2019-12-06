package BOM::Event::Actions::OTC;

use strict;
use warnings;

no indirect;

use feature 'state';

=head1 NAME

BOM::Event::Actions::OTC - deal with OTC events

=head1 DESCRIPTION

The peer-to-peer cashier feature (or "OTC" for over-the-counter) provides a way for
buyers and sellers to transfer funds using whichever methods they are able to negotiate
between themselves directly.

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
    DEFAULT_SOURCE                => 5,
    DEFAULT_STAFF                 => 'AUTOEXPIRY',
    ORDER_PENDING_STATUS          => 'pending',
    ORDER_CLIENT_CONFIRMED_STATUS => 'client-confirmed',
    ORDER_CANCELLED_STATUS        => 'cancelled',
    ORDER_COMPLETED_STATUS        => 'completed',
    ORDER_REFUNDER_STATUS         => 'refunded',
    ORDER_TIMED_OUT_STATUS        => 'timed-out',
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
            subject => 'New OTC agent registered',
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
    state $EXPIRATION_HANDLERS_FOR = {
        ORDER_PENDING_STATUS()          => \&_pending_expiration,
        ORDER_CLIENT_CONFIRMED_STATUS() => \&_client_confirmed_expiration,
        ORDER_CANCELLED_STATUS()        => sub { },
        ORDER_COMPLETED_STATUS()        => sub { },
        ORDER_REFUNDER_STATUS()         => sub { },
        ORDER_TIMED_OUT_STATUS()        => sub { },
    };

    $data->{$_} or die "Missing required attribute $_" for qw(broker_code order_id);

    my ($broker_code, $order_id) = @{$data}{qw(broker_code order_id)};

    my $client_dbh = BOM::Database::ClientDB->new({broker_code => $broker_code})->db->dbh;

    my $order_data = $client_dbh->selectrow_hashref(
        'SELECT id, status, client_confirmed, offer_currency currency FROM otc.order_list(?,?,?,?)',
        undef, $order_id, (undef) x 3,
    );

    die "Order $order_id isn't found" unless $order_data;

    my $status = $order_data->{status};
    die "Unexpected status $status for order $order_id" unless $EXPIRATION_HANDLERS_FOR->{$status};

    my $param = {
        broker_code => $broker_code,
        source      => $data->{source} // DEFAULT_SOURCE,
        staff       => $data->{staff} // DEFAULT_STAFF,
    };
    my $new_status = $EXPIRATION_HANDLERS_FOR->{$status}->($client_dbh, $order_data, $param);

    return 1 unless $new_status;

    my $redis = BOM::Config::RedisReplicated->redis_otc_write();
    $redis->publish(
        'OTC::ORDER::NOTIFICATION::' . $order_id,
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
    my ($client_dbh, $order_data, $param) = @_;

    my $escrow_account = BOM::User::Utility::escrow_for_currency($param->{broker_code}, $order_data->{currency});

    die "No Escrow account for broker $param->{broker_code} with currency $order_data->{currency}" unless $escrow_account;

    $client_dbh->selectrow_hashref('SELECT * FROM  otc.order_cancel(?, ?, ?, ?)',
        undef, $order_data->{id}, $escrow_account->loginid, $param->{source}, $param->{staff});

    return ORDER_CANCELLED_STATUS;
}

sub _client_confirmed_expiration {
    my ($client_dbh, $order_data, $param) = @_;

    $client_dbh->do('SELECT * FROM otc.order_update(?, ?)', undef, $order_data->{id}, ORDER_TIMED_OUT_STATUS);

    return ORDER_TIMED_OUT_STATUS;
}

1;
