package BOM::Event::Actions::CryptoSubscription;

use strict;
use warnings;
no indirect;

use Log::Any qw($log);
use BOM::Database::ClientDB;
use Syntax::Keyword::Try;

my $clientdb;
my $collectordb;

sub clientdb {
    return $clientdb //= do {
        my $clientdbi = BOM::Database::ClientDB->new({broker_code => 'CR'});
        $clientdbi->db->dbic;
    };
}

sub collectordb {
    return $collectordb //= do {
        my $collectordbi = BOM::Database::ClientDB->new({
            broker_code => 'FOG',
            operation   => 'collector',
        });
        $collectordbi->db->dbic;
    };
}

sub set_pending_transaction {
    my $transaction = shift;

    try {
        my $cursor_result = collectordb()->run(
            ping => sub {
                $_->selectall_arrayref(
                    'SELECT cryptocurrency.update_cursor(?, ?, ?)',
                    undef, $transaction->{currency},
                    $transaction->{block}, 'deposit'
                );
            });

        $log->warnf("%s: Can't update the cursor to block: %s", $transaction->{currency}, $transaction->{block}) unless $cursor_result;

        my $res = clientdb()->run(
            fixup => sub {
                $_->selectrow_hashref('select * from payment.find_crypto_by_addresses(?::VARCHAR[])', undef, $transaction->{to});
            });

        # generally a sweep transaction in the future it can help
        # in the recon report.
        unless ($res) {
            $log->warnf("Transaction not found: %s", $transaction->{hash});
            return undef;
        }

        # TODO: on duplicated payment we need to add this to check if we don't already
        # have the transaction and add it to payment.payment and transaction.transaction
        # as we are doing bom-postgres-clientdb/config/sql/functions/061_ctc_confirm_deposit.sql
        if ($res->{status} ne 'NEW') {
            $log->warnf("Address already confirmed for transaction: %s", $transaction->{hash});
            return undef;
        }

        # TODO: when the user send a transaction to a correct address but using
        # a different currency, we need to change the currency in the DATABASE and set
        # the transaction as pending.
        if ($res->{currency_code} ne $transaction->{currency}) {
            $log->warnf("Invalid currency for transaction: %s", $transaction->{hash});
            return undef;
        }

        # ignore amount 0
        unless ($transaction->{amount} > 0) {
            $log->warnf("Amount is zero for transaction: %s", $transaction->{hash});
            return undef;
        }

        my $result = clientdb()->run(
            ping => sub {
                $_->selectrow_array(
                    'SELECT payment.ctc_set_deposit_pending(?, ?, ?, ?)',
                    undef, $res->{address},
                    $transaction->{currency},
                    $transaction->{amount},
                    $transaction->{hash});
            });

        unless ($result) {
            $log->warnf("Can't set the status to pending for tx: %s", $transaction->{hash});
            return undef;
        }

        $log->debugf("Transaction status changed to pending: %s", $transaction->{hash});
    }
    catch {
        $log->errorf("Subscription error: %s", $_);
    };

    return 1;
}

1;

