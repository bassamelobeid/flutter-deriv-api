package BOM::User::InterDBTransfer;

use strict;
use warnings;
use Syntax::Keyword::Try;
use Log::Any                   qw($log);
use DataDog::DogStatsd::Helper qw(stats_inc);
use Format::Util::Numbers      qw(formatnumber);

=head2 transfer

Perform full transfer.

=cut

sub transfer {
    my %args = @_;

    # debit funds - any errors from this step are returned directly
    my $send_result = do_send(%args);

    # credit funds
    $args{from_payment_id} = $send_result->{payment_id};
    my $receive_result;
    try {
        $receive_result = do_receive(%args);
    } catch ($e) {
        # This is a temporary error such as db down. It will be retried by the daemon.
        $log->warnf('Error crediting interdb transfer with payment id %s from db %s in db %s: %s',
            $args{from_payment_id}, $args{from_db}, $args{to_db}, $e);
        die {
            error_code => 'TransferReceiveFailed',
            params     => [formatnumber('amount', $args{from_currency}, abs($args{from_amount})), $args{from_currency}]};
    }

    if ($receive_result eq 'revert') {
        try {
            my $revert_result = do_revert(%args);
        } catch ($e) {
            chomp $e;
            $log->warnf('Error reverting interdb transfer with payment id %s in db %s: %s', $args{from_payment_id}, $args{from_db}, $e);
            die {error_code => 'TransferRevertFailed'};
        }
        # need to return error to say transfer was reverted
        die {error_code => 'TransferReverted'};
    }

    return $send_result;
}

=head2 do_send

Perform the first, debit transaction of transfer.
Returns hashref of transaction_id, payment_id and transaction_time.

=cut

sub do_send {
    my %args = @_;

    # using 'ping' connection mode here and below to avoid duplicate transactions
    return $args{from_dbic}->run(
        ping => sub {
            $_->selectrow_hashref(
                'SELECT * FROM payment.interdb_transfer_send(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
                {Slice => {}},
                @args{
                    qw(from_db from_account_id from_currency from_amount from_fees from_staff from_remark
                        to_db to_account_id to_currency to_amount to_staff to_remark payment_gateway_code souce details)
                });
        });
}

=head2 do_receive

Perform the second, credit transaction of transfer.
Returns status as a string: 'ok', 'duplicate' or 'revert';

=cut

sub do_receive {
    my %args = @_;

    my $db_result = $args{to_dbic}->run(
        ping => sub {
            $_->selectrow_hashref(
                'SELECT * FROM payment.interdb_transfer_receive(?,?,?,?,?,?,?,?,?,?,?)',
                undef,
                @args{
                    qw(from_db from_payment_id from_currency
                        to_account_id to_currency to_amount to_staff to_remark payment_gateway_code souce details)
                });
        });

    if ($db_result->{result} ne 'revert') {
        # result can be ok or duplicate
        set_status(
            dbic              => $args{from_dbic},
            source_db         => $args{from_db},
            source_payment_id => $args{from_payment_id},
            status            => 'COMPLETE',
        );

        create_account_transfer_record(
            dbic                     => $args{from_dbic},
            payment_id               => $args{from_payment_id},
            corresponding_payment_id => $db_result->{payment_id},
            corresponding_db         => $args{to_db},
            corresponding_currency   => $args{to_currency},
            db_name                  => $args{from_db},             # only used for logging errors
        );
    }

    return $db_result->{result};
}

=head2 do_revert

Reverts the first transaction in the event of a permanent failure of second transaction.
Returns true if revert was successful.

=cut

sub do_revert {
    my %args = @_;

    stats_inc('interdb_transfer.revert', {tags => ['from_db:' . $args{from_db}, 'to_db:' . $args{to_db}]});

    my $result = $args{from_dbic}->run(
        ping => sub {
            $_->selectrow_array('SELECT payment.interdb_transfer_revert(?,?,?)', undef, @args{qw(from_db from_payment_id from_currency)});
        });

    set_status(
        dbic              => $args{to_dbic},
        source_db         => $args{from_db} . '_REVERT',    # source_db has a postfix for reverting transactions in receiving db outbox
        source_payment_id => $args{from_payment_id},
        status            => $result eq 'failed' ? 'MANUAL_INTERVENTION_REQUIRED' : 'REVERTED',
    );

    die "invalid account or currency changed\n" if $result eq 'failed';

    return $result;
}

=head2 set_status

Set status in outbox.

=cut

sub set_status {
    my %args = @_;

    try {
        $args{dbic}->run(
            fixup => sub {
                $_->do('SELECT payment.interdb_transfer_set_status(?,?,?)', undef, @args{qw(source_db source_payment_id status)});
            });
    } catch ($e) {
        $log->warnf('Set status for interdb transfer with payment id %s in db %s failed: %s', $args{source_payment_id}, $args{source_db}, $e);
        return 0;
    }

    return 1;
}

=head2 get_by_status

Gets items in outbox filtered by status and age, ordered by transaction time with limit.

=cut

sub get_by_status {
    my %args = @_;

    return $args{dbic}->run(
        fixup => sub {
            $_->selectall_arrayref('SELECT * FROM payment.interdb_transfer_get_by_status(?,?,?)', {Slice => {}}, @args{qw(status age_secs limit)});
        });
}

=head2 create_account_transfer_record

Creates an entry in payment.account_transfer table.

=cut

sub create_account_transfer_record {
    my %args = @_;

    try {
        return $args{dbic}->run(
            fixup => sub {
                $_->selectall_arrayref(
                    'SELECT * FROM payment.create_account_transfer_record(?,?,?, ?)',
                    {Slice => {}},
                    @args{qw(payment_id corresponding_payment_id corresponding_db corresponding_currency)});
            });
    } catch ($e) {
        $log->warnf('Create account_transfer record for interdb transfer with payment id %s in db %s failed: %s',
            $args{payment_id}, $args{db_name}, $e);
        return 0;
    }

    return 1;
}

1;
