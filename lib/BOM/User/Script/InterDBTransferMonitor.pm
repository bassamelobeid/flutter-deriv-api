use Object::Pad;

class BOM::User::Script::InterDBTransferMonitor;

use strict;
use warnings;
use Syntax::Keyword::Try;
use Log::Any                   qw($log);
use DataDog::DogStatsd::Helper qw(stats_inc);
use BOM::Database::ClientDB;
use BOM::User::InterDBTransfer;

use constant {
    BROKER_CODES          => [qw(VRTC VRW CR CRW MF MFW)],
    PROCESS_INTERVAL      => 10,                             # interval between ticks
    PENDING_PROCESS_DELAY => 5,                              # PENDING items must be at least these secs old before being processed
    PROCESS_LIMIT         => 50,                             # max number of items to process per tick, type & broker
};

has %dbs;

=head2 new

Constructor.

=cut

=head2 dbic

Creates and caches db connections.

=cut

method dbic ($broker, $operation) {
    return $dbs{$broker}{$operation} //= do {
        try {
            BOM::Database::ClientDB->new({
                    broker_code => $broker,
                    operation   => $operation,
                })->db->dbic;
        } catch ($e) {
            $log->warnf('cannot connect to db %s: %s', $broker, $e);
            undef;
        }
    };
}

=head2 run

Start the processing.

=cut

method run {

    while (1) {
        my $start = time;
        $self->process;
        my $next_tick = $start + PROCESS_INTERVAL - time;
        sleep($next_tick) if $next_tick > 0;
    }
}

=head2 process

Called for each interval.

=cut

method process {
    stats_inc('interdb_transfer_montitor.heartbeat');

    PENDING_BROKER:
    for my $broker ($self->BROKER_CODES->@*) {
        my $replica_db = $self->dbic($broker, 'replica') or next PENDING_BROKER;
        my $pending    = BOM::User::InterDBTransfer::get_by_status(
            dbic     => $replica_db,
            status   => 'PENDING',
            age_secs => $self->PENDING_PROCESS_DELAY,
            limit    => PROCESS_LIMIT,
        );

        for my $item (@$pending) {
            $item->@{qw(from_db from_payment_id from_currency)} = delete $item->@{qw(source_db source_payment_id source_currency)};

            $item->{from_dbic} = $self->dbic($item->{from_db}, 'write') or next PENDING_BROKER;
            $item->{to_dbic}   = $self->dbic($item->{to_db},   'write') or next PENDING_BROKER;

            try {
                BOM::User::InterDBTransfer::do_receive(%$item);
                stats_inc('interdb_transfer_monitor.receive.success', {tags => ['from_db:' . $item->{from_db}, 'to_db:' . $item->{to_db}]});
            } catch ($e) {
                $log->debugf(
                    'Error processing interdb transfer with payment id %s from db %s to db %s: %s',
                    $item->{from_payment_id},
                    $item->{from_db}, $item->{to_db}, $e
                );
                stats_inc('interdb_transfer_monitor.receive.fail', {tags => ['from_db:' . $item->{from_db}, 'to_db:' . $item->{to_db}]});
            }
        }
    }

    BROKER_REVERT:
    for my $broker ($self->BROKER_CODES->@*) {
        my $replica_db = $self->dbic($broker, 'replica') or next BROKER_REVERT;
        my $reverting  = BOM::User::InterDBTransfer::get_by_status(
            dbic   => $replica_db,
            status => 'REVERTING',
            limit  => PROCESS_LIMIT,
        );

        for my $item (@$reverting) {
            $item->@{qw(from_payment_id from_currency)} = delete $item->@{qw(source_payment_id source_currency)};
            $item->{from_db}                            = $item->{source_db} =~ s/_REVERT$//r;
            $item->{to_db}                              = $broker;
            $item->{from_dbic}                          = $self->dbic($item->{from_db}, 'write') or next BROKER_REVERT;
            $item->{to_dbic}                            = $self->dbic($item->{to_db},   'write') or next BROKER_REVERT;

            try {
                my $res = BOM::User::InterDBTransfer::do_revert(%$item);
                stats_inc('interdb_transfer_montitor.revert.success', {tags => ['from_db:' . $item->{from_db}, 'to_db:' . $item->{to_db}]})
                    if $res ne 'failed';
            } catch ($e) {
                chomp $e;
                $log->warnf('Error reverting interdb transfer with payment id %s in db %s: %s', $item->{from_payment_id}, $item->{from_db}, $e);
                stats_inc('interdb_transfer_montitor.revert.fail', {tags => ['from_db:' . $item->{from_db}, 'to_db:' . $item->{to_db}]});
            }
        }
    }
}

1;
