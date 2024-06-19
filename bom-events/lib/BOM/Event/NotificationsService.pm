package BOM::Event::NotificationsService;

use strict;
use warnings;

use Log::Any qw($log);
use DateTime;
use BOM::Config::Redis;
use BOM::Platform::Event::Emitter;
use BOM::Database::ClientDB;

use constant SEPARATOR      => '::';
use constant DAY_IN_SECONDS => 24 * 60 * 60;

my $notification_queue             = join(SEPARATOR, 'NOTIFICATION_QUEUE',      uc DateTime->now()->day_name);
my $notification_queue_done        = join(SEPARATOR, 'NOTIFICATION_QUEUE_DONE', uc DateTime->now()->day_name);
my $notification_mul_dc_queue      = 'NOTIFICATION_MUL_DC_QUEUE';
my $notification_mul_dc_queue_done = join(SEPARATOR, 'NOTIFICATION_MUL_DC_QUEUE_DONE', uc DateTime->now()->day_name);

=head1 NAME

BOM::Event::NotificationsService

=head1 SYNOPSYS

    use BOM::Event::NotificationsService;

    my $notification_service = BOM::Event::NotificationsService->new(
        redis => BOM::Config::Redis::redis_expiryq_write
    );

    $notifications_service->dequeue_notifications();
    $notifications_service->dequeue_dc_notifications();

=head1 DESCRIPTION

This module will serve the purpose of processing pending contract's notification jobs inside queues.

=cut

=head2 new

Creates a new inscance of the class. Arguments:

=over 1

=item B<redis>

FQDN of the corresponding redis module.

=back

=cut

sub new {
    my ($class, %args) = @_;

    my $self = bless {
        redis => $args{redis} // die($log->error("redis is required")),
    }, $class;

    return $self;
}

=head2 dequeue_dc_notifications

Send notification for all of the contracts with close to expire deal cancellation option.

=cut

sub dequeue_dc_notifications {
    my $self  = shift;
    my $redis = $self->{redis};

    my @cids = @{$redis->zrangebyscore($notification_mul_dc_queue, time, time + 60)};

    foreach my $cid (@cids) {
        next if $redis->sismember($notification_mul_dc_queue_done, $cid);

        # Send notifications...
        my ($contract_id, $login_id) = split '::', $cid;

        $self->_send_multiplier_dc_notification($login_id, $contract_id);

        # Remove from queue.
        $redis->zrem($notification_mul_dc_queue, $cid);

        if (!$redis->exists($notification_mul_dc_queue_done)) {
            $redis->sadd($notification_mul_dc_queue_done, $cid);
            $redis->expire($notification_mul_dc_queue_done, DAY_IN_SECONDS);
            next;
        }

        $redis->sadd($notification_mul_dc_queue_done, $cid);
    }
}

=head2 _send_multiplier_dc_notification

Responsible for emitting events of already processed deal cancellation enabled jobs.

=cut

sub _send_multiplier_dc_notification {
    my ($self, $login_id, $contract_id) = @_;

    my $args = {
        loginid     => $login_id,
        contract_id => $contract_id,
    };

    BOM::Platform::Event::Emitter::emit('multiplier_near_dc_notification', $args);
}

=head2 dequeue_notifications

Process all of the jobs(contracts that are close to TP/SL threshold) that are pending in the queue.

=cut

sub dequeue_notifications {
    my $self  = shift;
    my $redis = $self->{redis};

    my $cid = $redis->spop($notification_queue);
    return if (not($cid) or $redis->sismember($notification_queue_done, $cid));

    # $cid data pattern is something like this:
    # "279::CR90000000::USD::10.00::539::::::::::EN::NOTIF"
    my @info = split '::', $cid;

    my ($contract_id, $login_id) = @info;
    my $should_notify = $info[-1] eq 'NOTIF';

    $self->_send_multiplier_expiry_notification($login_id, $contract_id, $should_notify);

    if ($redis->exists($notification_queue_done)) {
        return $redis->sadd($notification_queue_done, $cid);
    }

    $redis->sadd($notification_queue_done, $cid);
    $redis->expire($notification_queue_done, DAY_IN_SECONDS);
}

=head2 _send_multiplier_expiry_notification

Sends notifications of Multiplier TP/SL contracts.

=cut

sub _send_multiplier_expiry_notification {
    my ($self, $login_id, $contract_id, $should_notify) = @_;

    return if not $should_notify;

    my $args = {
        loginid     => $login_id,
        contract_id => $contract_id,
    };

    BOM::Platform::Event::Emitter::emit('multiplier_near_expire_notification', $args);
}

1;
