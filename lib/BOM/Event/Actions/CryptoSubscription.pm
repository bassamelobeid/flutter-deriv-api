package BOM::Event::Actions::CryptoSubscription;

use strict;
use warnings;
no indirect;

use Log::Any qw($log);
use List::Util qw(any all);
use BOM::Database::ClientDB;
use BOM::Config;
use Syntax::Keyword::Try;
use Format::Util::Numbers qw/financialrounding/;
use BOM::Platform::Event::Emitter;

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

=head2 set_pending_transaction

Set the transaction as pending in payment.cryptocurrency if the transaction
pass for all the requirements:
- Found in the database
- Is currently in the NEW state
- If is not in the new state it needs to be CONFIRMED and have the field blockchain_txn populated
    in this case a new row will be created and set as pending(duplicated transaction to the same address)
- Same currency as we have in the database
- No zero amount

On issue setting the transaction as pending in the database a new event will be triggered to
try it again after some seconds.

=cut

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

        my $payment_rows = clientdb()->run(
            fixup => sub {
                my $sth = $_->prepare('select * from payment.find_crypto_by_addresses(?::VARCHAR[])');
                $sth->execute($transaction->{to});
                return $sth->fetchall_arrayref({});
            });

        my @rows = $payment_rows->@*;

        # generally a sweep transaction
        unless (scalar @rows) {
            $log->warnf("Transaction not found: %s", $transaction->{hash});
            return undef;
        }

        my %rows_ref;
        map { push(@{$rows_ref{$_->{address}}}, $_) } @rows;

        for my $address (keys %rows_ref) {
            my @payment = $rows_ref{$address}->@*;
            # transaction already confirmed by subscription
            if (any { $_->{blockchain_txn} && $_->{blockchain_txn} eq $transaction->{hash} } @payment) {
                $log->debugf("Address already confirmed by subscription for transaction: %s", $transaction->{hash});
                return undef;
            }

            # transaction already confirmed by confirmation daemon and does not have a transaction hash
            # in this case we can't risk to duplicate the transaction so we just ignore it
            # this is a check for the transactions done to before the subscription impl in place
            if (any { $_->{status} ne 'NEW' && !$_->{blockchain_txn} } @payment) {
                $log->debugf("Address already confirmed by confirmation daemon for transaction: %s", $transaction->{hash});
                return undef;
            }

            # address has no new transaction so it's safe to create a new one since we
            # already verified that the transaction hash is not present on the table
            if (all { $_->{status} ne 'NEW' } @payment) {
                my $result = clientdb()->run(
                    ping => sub {
                        my $sth = $_->prepare('SELECT payment.ctc_insert_new_deposit(?, ?, ?, ?, ?)');
                        $sth->execute($address, $transaction->{currency}, $payment[0]->{client_loginid}, $transaction->{fee}, $transaction->{hash})
                            or die $sth->errstr;
                    });

                unless ($result) {
                    $log->warnf("Duplicate deposit rejected for %s transaction: %s", $transaction->{currency}, $transaction->{hash});
                    return undef;
                }
            }

            # for omnicore we need to check if the property id is correct
            if ($transaction->{property_id}
                && ($transaction->{property_id} + 0) != (BOM::Config::crypto()->{$transaction->{currency}}->{property_id} + 0))
            {
                $log->warnf("%s - Invalid property ID for transaction: %s", $transaction->{currency}, $transaction->{hash});
                return undef;
            }

            # TODO: when the user send a transaction to a correct address but using
            # a different currency, we need to change the currency in the DATABASE and set
            # the transaction as pending.
            if (any { $_->{currency_code} ne $transaction->{currency} } @payment) {
                $log->warnf("Invalid currency for transaction: %s", $transaction->{hash});
                return undef;
            }

            # ignore amount 0
            unless ($transaction->{amount} > 0) {
                $log->warnf("Amount is zero for transaction: %s", $transaction->{hash});
                return undef;
            }

            my $result = update_transaction_status_to_pending($transaction, $address);

            unless ($result) {
                $log->warnf("Can't set the status to pending for tx: %s", $transaction->{hash});

                # if we don't receive the response from the database we need to retry sending it
                # creating a new event with the same transaction so it will try to set it as pending
                # later again
                my $emit;
                my $error = "No error returned";
                try {
                    $emit = BOM::Platform::Event::Emitter::emit('set_pending_transaction', $transaction);
                }
                catch {
                    $error = $@;
                };

                $log->warnf(
                    'Failed to emit event for currency: %s, transaction: %s, error: %s',
                    $transaction->{currency},
                    $transaction->{hash}, $error
                ) unless $emit;

                return undef;
            }

            $log->debugf("Transaction status changed to pending: %s", $transaction->{hash});

            last;
        }
    }
    catch {
        $log->errorf("Subscription error: %s", $@);
    };

    return 1;
}

=head2 update_transaction_status_to_pending

Update the status to pending in the database

=cut

sub update_transaction_status_to_pending {
    my ($transaction, $address) = @_;
    my $result = clientdb()->run(
        ping => sub {
            $_->selectrow_array(
                'SELECT payment.ctc_set_deposit_pending(?, ?, ?, ?)',
                undef, $address,
                $transaction->{currency},
                financialrounding('amount', $transaction->{currency}, $transaction->{amount}),
                $transaction->{hash});
        });
    return $result;
}

1;

