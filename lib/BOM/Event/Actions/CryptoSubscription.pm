package BOM::Event::Actions::CryptoSubscription;

use strict;
use warnings;
no indirect;

use Log::Any qw($log);
use List::Util qw(any all first);
use Syntax::Keyword::Try;
use DataDog::DogStatsd::Helper qw/stats_inc/;

use BOM::Database::ClientDB;
use BOM::Platform::Event::Emitter;
use BOM::CTC::Currency;
use BOM::CTC::Constants qw(:transaction :datadog);
use BOM::CTC::Helper;
use BOM::Event::Utility qw(exception_logged);

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

sub subscription {
    my $transaction = shift;

    set_pending_transaction($transaction);
    set_transaction_fee($transaction);
}

=head2 set_transaction_fee

We store in the database just the estimation fee since we can't wait until
the transaction to be completed in the sync process, here in this function
we have the final fee returned from the node so we need to update the final fee
in the database.

=over 4

=item * C<transaction> - transaction reference containing the blockchain data

=back

=cut

sub set_transaction_fee {
    my $transaction = shift;
    my $currency = BOM::CTC::Currency->new(currency_code => $transaction->{currency});

    # we are specifying the currency here just for performance purpose, since for the other currencies
    # this value is supposed to be correct, we check using the fee_currency because of the ERC20 contracts;
    if ($transaction->{type} eq 'send' && $transaction->{fee_currency} eq 'ETH' && $transaction->{fee}) {
        clientdb()->run(
            ping => sub {
                my $sth = $_->prepare('select payment.ctc_update_transaction_fee(?, ?, ?)');
                $sth->execute($transaction->{hash}, $transaction->{currency}, $currency->get_unformatted_fee($transaction->{fee}));
            });
    }
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

=over 4

=item * C<transaction> - transaction reference containing the blockchain data

=back

=cut

sub set_pending_transaction {
    my $transaction   = shift;
    my $currency_code = $transaction->{currency};
    my $currency      = BOM::CTC::Currency->new(currency_code => $currency_code);

    try {

        # the update cursor call is done before because
        # we need to update the database with the last block
        # started since once we start the subscription daemon
        # again it will continue including the latest block
        # inserted in the database
        my $cursor_result = collectordb()->run(
            ping => sub {
                $_->selectall_arrayref('SELECT cryptocurrency.update_cursor(?, ?, ?)',
                    undef, $currency_code, $transaction->{block}, TRANSACTION_TYPE_DEPOSIT);
            });
        $log->warnf("%s: Can't update the cursor to block: %s", $currency_code, $transaction->{block}) unless $cursor_result;

        return undef if (!$transaction->{type} || $transaction->{type} eq 'send');

        # get all the payments related to the `to` address from the transaction
        # since this is only for deposits we don't care about the `from` address
        # also, the subscription daemon takes care about the multiple receivers
        # transactions, so in this daemon we are going to always receive just 1 to 1 transactions.
        my $payment_rows = clientdb()->run(
            fixup => sub {
                my $sth = $_->prepare('select * from payment.find_crypto_by_addresses(?::VARCHAR[])');
                $sth->execute($transaction->{to});
                return $sth->fetchall_arrayref({});
            });

        my @rows = $payment_rows->@*;

        # generally a sweep transaction
        unless (scalar @rows) {
            my $reserved_addresses = $currency->get_reserved_addresses();
            my $address            = shift $transaction->{to}->@*;
            # for transactions from our internal sweeps or external wallets
            # we don't want to print the error message since they are happening
            # correctly

            unless (any { $currency->compare_addresses($address, $_) } $reserved_addresses->@*) {
                $log->warnf("%s Transaction not found for address: %s and transaction: %s", $transaction->{currency}, $address, $transaction->{hash});
                stats_inc(DD_METRIC_PREFIX . 'subscription.set_pending', {tags => ['currency:' . $transaction->{currency}, 'status:failed']});
            }
            # we want to ignore the transaction anyway
            # since the sweeps and external transactions
            # do not require confirmation
            return undef;
        }

        my %rows_ref;
        push($rows_ref{$_->{address}}->@*, $_) for @rows;

        for my $address (keys %rows_ref) {
            my @payment = $rows_ref{$address}->@*;

            return undef unless ($transaction->{type});

            # ignores those that are not internal transfer and transactions that already confirmed by subscription
            if ($transaction->{type} ne 'internal'
                && any { $_->{blockchain_txn} && $_->{blockchain_txn} eq $transaction->{hash} && $_->{status} ne 'NEW' } @payment)
            {
                $log->debugf("Address already confirmed by subscription for transaction: %s", $transaction->{hash});
                return undef;
            }

            # transaction already confirmed by confirmation daemon and does not have a transaction hash
            # in this case we can't risk to duplicate the transaction so we just ignore it
            # this is a check for the transactions done to before the subscription impl in place
            if (any { $_->{status} ne 'NEW' && !$_->{blockchain_txn} && $_->{transaction_type} ne TRANSACTION_TYPE_WITHDRAWAL } @payment) {
                $log->debugf("Address already confirmed by confirmation daemon for transaction: %s", $transaction->{hash});
                return undef;
            }

            # TODO: when the user send a transaction to a correct address but using
            # a different currency, we need to change the currency in the DATABASE and set
            # the transaction as pending.
            if (any { $_->{currency_code} ne $currency_code } @payment) {
                $log->warnf("Invalid currency for transaction: %s", $transaction->{hash});
                stats_inc(DD_METRIC_PREFIX . 'subscription.set_pending', {tags => ['currency:' . $transaction->{currency}, 'status:failed']});
                return undef;
            }

            # ignore transaction with 0 amount if it is not internal transfer
            unless ($currency->transaction_amount_not_zero($transaction)) {
                $log->warnf("Amount is zero for transaction: %s", $transaction->{hash});
                stats_inc(DD_METRIC_PREFIX . 'subscription.set_pending', {tags => ['currency:' . $transaction->{currency}, 'status:failed']});
                return undef;
            }

            # for omnicore we need to check if the property id is correct
            if ($transaction->{property_id}
                && ($transaction->{property_id} + 0) != ($currency->get_property_id() + 0))
            {
                $log->warnf("%s - Invalid property ID for transaction: %s", $currency_code, $transaction->{hash});
                stats_inc(DD_METRIC_PREFIX . 'subscription.set_pending', {tags => ['currency:' . $currency_code, 'status:failed']});
                return undef;
            }

            # insert new duplicated deposit if needed
            # requirements to insert a new deposit:
            #  - database already contains one or more transactions to the same address
            return undef unless insert_new_deposit($transaction, \@payment);

            my $result = update_transaction_status_to_pending($transaction, $address);

            if ($result) {
                my ($emit, $error);
                try {
                    my $record = first { ($_->{transaction_type} // '') eq 'deposit' } @payment;

                    $emit = BOM::Platform::Event::Emitter::emit(
                        'new_crypto_address',
                        {
                            loginid => $record->{client_loginid},
                        });
                }
                catch {
                    $error = $@;
                }

                $log->warnf(
                    'Failed to emit event - new_crypto_address - for currency: %s, loginid: %s, after marking transaction: %s as pending with error: %s',
                    $currency_code, ($payment[0]->{client_loginid} // ''), $transaction->{hash}, $error
                ) unless $emit;
            } else {
                $log->warnf("Can't set the status to pending for tx: %s", $transaction->{hash});
                stats_inc(DD_METRIC_PREFIX . 'subscription.set_pending', {tags => ['currency:' . $transaction->{currency}, 'status:failed']});

                # if we don't receive the response from the database we need to retry sending it
                # creating a new event with the same transaction so it will try to set it as pending
                # later again
                my $emit;
                my $error = "No error returned";
                try {
                    $emit = BOM::Platform::Event::Emitter::emit('crypto_subscription', $transaction);
                }
                catch {
                    $error = $@;
                    exception_logged();
                }

                $log->warnf('Failed to emit event for currency: %s, transaction: %s, error: %s', $currency_code, $transaction->{hash}, $error)
                    unless $emit;

                return undef;
            }

            $log->debugf("Transaction status changed to pending: %s", $transaction->{hash});
            stats_inc(DD_METRIC_PREFIX . 'subscription.set_pending', {tags => ['currency:' . $transaction->{currency}, 'status:success']});

            last;
        }

    }
    catch {
        $log->errorf("Subscription error: %s", $@);
        exception_logged();
        stats_inc(DD_METRIC_PREFIX . 'subscription.set_pending', {tags => ['currency:' . $transaction->{currency}, 'status:failed']});
        return undef;
    }

    return 1;
}

=head2 insert_new_deposit

If the database already contains any transaction to the same address no matter the status
we insert a new database row to the second deposit

=over 4

=item* C<transaction> transaction object L<https://github.com/regentmarkets/bom-cryptocurrency/blob/master/lib/BOM/CTC/Subscription.pm#L113-L120>

=item* C<payment> payment.cryptocurrency rows related to the address

=back

Return 1 for no errors and 0 when error is found inserting the row to the database.

=cut

sub insert_new_deposit {
    my ($transaction, $payment_list) = @_;
    my $currency_code = $transaction->{currency};

    return 0 unless $payment_list;

    my @payment = @$payment_list;
    return 0 unless @payment > 0;

    # address has no new transaction so it's safe to create a new one since we
    # already verified that the transaction hash is not present on the table
    my $no_new_found = any { $_->{status} eq 'NEW' and not $_->{blockchain_txn} } @payment;
    # or in case we already have another transaction to this same address
    # we need to be able to create another row in the payment database too
    # so we are going to have two rows in the new status but with different
    # transactions.
    my $is_txn_exists = any { $_->{blockchain_txn} and $_->{blockchain_txn} eq $transaction->{hash} and $_->{status} eq 'NEW' } @payment;

    unless ($no_new_found || $is_txn_exists) {

        my $record = first { $_->{transaction_type} eq 'deposit' } @payment;
        unless ($record and $record->{client_loginid}) {
            $log->warnf(
                "Deposit rejected for %s transaction: %s , Error: Cannot get the client loginid. Please inform the crypto team to investigate the transaction.",
                $currency_code, $transaction->{hash});
            stats_inc(DD_METRIC_PREFIX . 'subscription.insert_new', {tags => ['currency:' . $currency_code, 'status:failed']});
            return 0;
        }

        my $result = clientdb()->run(
            ping => sub {
                my $sth = $_->prepare('SELECT payment.ctc_insert_new_deposit_address(?, ?, ?, ?, ?)');
                $sth->execute($payment[0]->{address}, $currency_code, $record->{client_loginid}, $transaction->{fee}, $transaction->{hash});
            });

        # this is just a safe check in case we get some error from the database
        # but we should not reach this point because we are verifying the PKs conflicts
        # before this point
        unless ($result) {
            $log->warnf("Duplicate deposit rejected for %s transaction: %s", $currency_code, $transaction->{hash});
            stats_inc(DD_METRIC_PREFIX . 'subscription.insert_new', {tags => ['currency:' . $currency_code, 'status:failed']});
            return 0;
        } else {
            stats_inc(DD_METRIC_PREFIX . 'subscription.insert_new', {tags => ['currency:' . $transaction->{currency}, 'status:success']});
        }
    }

    return 1;
}

=head2 update_transaction_status_to_pending

Update the status to pending in the database

=cut

sub update_transaction_status_to_pending {
    my ($transaction, $address) = @_;
    my $currency_code = $transaction->{currency};

    my $result = clientdb()->run(
        ping => sub {
            $_->selectrow_array(
                'SELECT payment.ctc_set_deposit_pending(?, ?, ?, ?)',
                undef, $address, $currency_code, $transaction->{amount} > 0 ? $transaction->{amount} : undef,
                $transaction->{hash});
        });
    return $result;
}

=head2 new_crypto_address

Generate a new crypto address for client currency

=cut

sub new_crypto_address {
    my $data = shift;

    return undef unless $data->{loginid};

    my $client = BOM::User::Client->new({loginid => $data->{loginid}})
        or die 'Could not instantiate client for login ID ' . $data->{loginid};

    my $currency = $client->account ? $client->account->currency_code : '';

    return undef unless $currency;

    return undef unless LandingCompany::Registry::get_currency_type($currency) eq 'crypto';

    try {
        my $helper = BOM::CTC::Helper->new(client => $client);
        my ($id, $address) = $helper->get_deposit_id_and_address();
        return $address;
    }
    catch {
        $log->errorf('Failed to generate address for new_crypto_address event. Details: loginid %s, currency: %s, and error: %s',
            $client->loginid, $currency, $@)
    }

    return undef;
}

1;
