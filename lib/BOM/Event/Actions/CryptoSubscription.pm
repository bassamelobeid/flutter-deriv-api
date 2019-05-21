package BOM::Event::Actions::CryptoSubscription;

use strict;
use warnings;
no indirect;

use Log::Any qw($log);
use BOM::CTC::Currency;
use BOM::Database::ClientDB;

sub set_pending_transaction {
    my $transaction = shift;

    my $clientdb = BOM::Database::ClientDB->new({broker_code => 'CR'});
    my $dbic = $clientdb->db->dbic;

    my $currency = BOM::CTC::Currency->new($transaction->{currency});

    my @addresses = map { $currency->get_valid_address($_)->{address} } $transaction->{to}->@*;

    my $res = $dbic->run(
        fixup => sub {
            $_->selectrow_hashref('select * from payment.find_crypto_by_addresses(?::VARCHAR[])', undef, \@addresses);
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

    my $result = $dbic->run(
        ping => sub {
            $_->selectrow_array(
                'SELECT payment.ctc_set_deposit_pending(?, ?, ?, ?)',
                undef, $res->{address},
                $transaction->{currency},
                $currency->get_formated_amount($transaction->{amount}),
                $transaction->{hash});
        });

    unless ($result) {
        $log->warnf("Can't set the status to pending for tx: %s", $transaction->{hash});
        return undef;
    }

    $log->infof("Transaction status changed to pending: %s", $transaction->{hash});
    return 1;
}

1;

