package BOM::Event::Actions::CryptoSubscription;

use strict;
use warnings;
no indirect;

use Log::Any qw($log);
use List::Util qw(any all first);
use Syntax::Keyword::Try;
use DataDog::DogStatsd::Helper qw/stats_inc/;

use BOM::Platform::Event::Emitter;
use BOM::CTC::Currency;
use BOM::CTC::Database;
use BOM::CTC::Constants qw(:transaction :datadog);
use BOM::CTC::Helper;
use BOM::Event::Utility qw(exception_logged);
use BOM::CTC::TP::API::BTC;

=head1 NAME

BOM::Event::Actions::CryptoSubscription

=head1 DESCRIPTION

Provides event handlers for crypto subscriptions.

=cut

use BOM::Config::Runtime;
use BOM::Config::CurrencyConfig;

my $cryptodb_dbic;

sub cryptodb {
    return $cryptodb_dbic //= do {
        my $cryptodb = BOM::CTC::Database->new();
        $cryptodb->cryptodb_dbic();
    };
}

sub subscription {
    my $transaction = shift;

    set_pending_transaction($transaction);
    set_transaction_fee($transaction);
}

my $loop = IO::Async::Loop->new;
my $tp_api;

=head2 _tp_api

Private subroutine whose purpose is to add the async
C<BOM::CTC::TP::API::BTC> into the C<IO::Async::Loop>
so to use safe the async subs contained in the
C<BOM::CTC::TP::API::BTC>

Returns a C<BOM::CTC::TP::API::BTC> object

=cut

sub _tp_api {
    return $tp_api //= do {
        $loop->add($tp_api = BOM::CTC::TP::API::BTC->new());
        $tp_api;
    }
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
    my $currency    = BOM::CTC::Currency->new(currency_code => $transaction->{currency});

    # we are specifying the currency here just for performance purpose, since for the other currencies
    # this value is supposed to be correct, we check using the fee_currency because of the ERC20 contracts;
    if ($transaction->{type} eq 'send' && $transaction->{fee_currency} eq 'ETH' && $transaction->{fee}) {
        cryptodb()->run(
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
    my $error;

    my $to_address   = $transaction->{to};
    my $from_address = $transaction->{from};

    try {
        return {
            status => 0,
            error  => sprintf("withdrawal transaction: %s", $transaction->{hash})}
            unless $transaction->{type} && $transaction->{type} ne 'send';
        # if the from address is our main wallet and the transaction type is not send this is
        # an internal sweep transaction
        return {
            status => 0,
            error  => sprintf("`from` address is main address for transaction: %s", $transaction->{hash})}
            if $from_address && lc $from_address eq lc $currency->account_config->{account}->{address};

        # TODO this needs to be enabled once we have the rinkeby network in our QA enviroment
        # we will not reach this point on production, but in QA this is actually very easy since we
        # are sending transactions from our local node, so we need this block here.
        # return {
        #     status => 0,
        #     error  => sprintf("internal transactions not allowed, `from`: %s `to`: %s", $from_address // "", $to_address)}
        #     if $transaction->{type} eq TRANSACTION_TYPE_INTERNAL;

        # get all the payments related to the `to` address from the transaction
        # since this is only for deposits we don't care about the `from` address
        # also, the subscription daemon takes care about the multiple receivers
        # transactions, so in this daemon we are going to always receive just 1 to 1 transactions.
        my $payment_rows = cryptodb()->run(
            fixup => sub {
                # we don't use the currency as parameter here because we need to know when the client sent
                # a transaction to a different currency he/she should be doing
                my $sth = $_->prepare('select * from payment.find_crypto_deposit_by_address(?)');
                $sth->execute($to_address);
                return $sth->fetchall_arrayref({});
            });

        # generally a sweep transaction
        unless ($payment_rows && $payment_rows->@*) {
            my $reserved_addresses = $currency->get_reserved_addresses();
            # for transactions from our internal sweeps or external wallets
            # we don't want to print the error message since they are happening
            # correctly

            unless (any { $currency->compare_addresses($to_address, $_) || $currency->compare_addresses($from_address, $_) } $reserved_addresses->@*)
            {
                $error = sprintf("%s Transaction not found for address: %s and transaction: %s", $currency_code, $to_address, $transaction->{hash});
                $log->warn($error);
                stats_inc(DD_METRIC_PREFIX . 'subscription.set_pending', {tags => ['currency:' . $currency_code, 'status:failed']});
            } else {
                $error = sprintf("%s Transaction not found but it is a sweep for address: %s and transaction: %s",
                    $currency_code, $to_address, $transaction->{hash});
                $log->debug($error);
            }
            # we want to ignore the transaction anyway
            # since the sweeps and external transactions
            # do not require confirmation
            return {
                status => 0,
                error  => $error
            };
        }

        my @payment = $payment_rows->@*;

        if (my $correct_currency = first { $_->{currency_code} ne $currency_code } @payment) {
            $error = sprintf(
                "Invalid currency, expecting: %s, received: %s, for transaction: %s",
                $correct_currency->{currency_code},
                $currency_code, $transaction->{hash});
            $log->warn($error);
            stats_inc(DD_METRIC_PREFIX . 'subscription.wrong_currency_deposit',
                {tags => ['currency:' . $currency_code, 'wrong_currency:' . $currency_code]});
            return {
                status => 0,
                error  => $error
            };
        }

        if (any { $_->{blockchain_txn} && $_->{blockchain_txn} eq $transaction->{hash} && $_->{status} ne 'NEW' } @payment) {
            $error = sprintf("Address already confirmed by subscription for transaction: %s", $transaction->{hash});
            $log->debugf($error);
            return {
                status => 0,
                error  => $error
            };
        }

        # transaction already confirmed by confirmation daemon and does not have a transaction hash
        # in this case we can't risk to duplicate the transaction so we just ignore it
        # this is a check for the transactions which done before implement the subscription daemon
        if (any { $_->{status} ne 'NEW' && !$_->{blockchain_txn} } @payment) {
            $error = sprintf("Address already confirmed by confirmation daemon for transaction: %s", $transaction->{hash});
            $log->debugf($error);
            return {
                status => 0,
                error  => $error
            };
        }

        # ignore transaction with 0 amount if it is not internal transfer
        unless ($currency->transaction_amount_not_zero($transaction)) {
            $error = sprintf("Amount is zero for transaction: %s", $transaction->{hash});
            $log->warnf($error);
            stats_inc(DD_METRIC_PREFIX . 'subscription.set_pending', {tags => ['currency:' . $currency_code, 'status:failed']});
            return {
                status => 0,
                error  => $error
            };
        }

        # for omnicore we need to check if the property id is correct
        if ($transaction->{property_id}
            && ($transaction->{property_id} + 0) != ($currency->get_property_id() + 0))
        {
            $error = sprintf("%s - Invalid property ID for transaction: %s", $currency_code, $transaction->{hash});
            $log->warnf($error);
            stats_inc(DD_METRIC_PREFIX . 'subscription.set_pending', {tags => ['currency:' . $currency_code, 'status:failed']});
            return {
                status => 0,
                error  => $error
            };
        }

        # insert new duplicated deposit if needed
        # requirements to insert a new deposit:
        #  - database already contains one or more transactions to the same address
        $error = "Transaction already in the database";
        return {
            status => 0,
            error  => $error
        } unless insert_new_deposit($transaction, \@payment);

        my $result = update_transaction_status_to_pending($transaction, $to_address);

        if ($result) {

            my $app_config = BOM::Config::Runtime->instance->app_config;
            $app_config->check_for_update;

            # we should retain the address if the deposit amount does not reach the specified threshold
            my $retain_address = requires_address_retention($currency->currency_code, $to_address);

            my ($emit, $error);
            try {
                my $client_loginid = $payment[0]->{client_loginid};

                $emit = emit_new_address_call($client_loginid, $retain_address, $to_address);
            } catch ($e) {
                $error = $e;
            }

            $log->warnf(
                'Failed to emit event - new_crypto_address - for currency: %s, loginid: %s, after marking transaction: %s as pending with error: %s',
                $currency_code, ($payment[0]->{client_loginid} // ''), $transaction->{hash}, $error
            ) unless $emit;
        } else {
            $log->debugf("Can't set the status to pending for tx: %s", $transaction->{hash});
            stats_inc(DD_METRIC_PREFIX . 'subscription.set_pending', {tags => ['currency:' . $currency_code, 'status:failed']});

            # if we don't receive the response from the database we need to retry sending it
            # creating a new event with the same transaction so it will try to set it as pending
            # later again
            my $emit;
            my $error = "No error returned";
            try {
                $emit = BOM::Platform::Event::Emitter::emit('crypto_subscription', $transaction);
            } catch ($e) {
                $error = $e;
                exception_logged();
            }

            $error = sprintf("Failed to emit event for currency: %s, transaction: %s, error: %s", $currency_code, $transaction->{hash}, $error);
            $log->warnf($error)
                unless $emit;

            return {
                status => 0,
                error  => $error
            };
        }

        $log->debugf("Transaction status changed to pending: %s", $transaction->{hash});
        stats_inc(DD_METRIC_PREFIX . 'subscription.set_pending', {tags => ['currency:' . $currency_code, 'status:success']});

    } catch ($e) {
        $error = sprintf("Subscription error: %s", $e);
        $log->errorf($error);
        exception_logged();
        stats_inc(DD_METRIC_PREFIX . 'subscription.set_pending', {tags => ['currency:' . $currency_code, 'status:failed']});
        return {
            status => 0,
            error  => $error
        };
    }

    return {status => 1};
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

        my $client_loginid = $payment[0]->{client_loginid};
        unless ($client_loginid) {
            $log->warnf(
                "Deposit rejected for %s transaction: %s , Error: Cannot get the client loginid. Please inform the crypto team to investigate the transaction.",
                $currency_code, $transaction->{hash});
            stats_inc(DD_METRIC_PREFIX . 'subscription.insert_new', {tags => ['currency:' . $currency_code, 'status:failed']});
            return 0;
        }

        my $result = cryptodb()->run(
            ping => sub {
                my $sth = $_->prepare('SELECT payment.ctc_insert_new_deposit_address(?, ?, ?, ?)');
                $sth->execute($payment[0]->{address}, $currency_code, $client_loginid, $transaction->{hash});
            });

        # this is just a safe check in case we get some error from the database
        # but we should not reach this point because we are verifying the PKs conflicts
        # before this point
        unless ($result) {
            $log->warnf("Duplicate deposit rejected for %s transaction: %s", $currency_code, $transaction->{hash});
            stats_inc(DD_METRIC_PREFIX . 'subscription.insert_new', {tags => ['currency:' . $currency_code, 'status:failed']});
            return 0;
        } else {
            stats_inc(DD_METRIC_PREFIX . 'subscription.insert_new', {tags => ['currency:' . $currency_code, 'status:success']});
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

    my $result = cryptodb()->run(
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

    my $helper = BOM::CTC::Helper->new(client => $client);

    try {
        my ($id, $address) = $helper->get_deposit_id_and_address($data->{retain_address} ? $data->{address} // undef : undef);
        return $address;
    } catch ($e) {
        stats_inc(DD_METRIC_PREFIX . 'subscription.new_address', {tags => ['currency:' . $currency, 'status:failed']});
    }

    return undef;
}

=head2 requires_address_retention

Check if the amount sent by the client plus the other transactions already sent to this address
are bigger than the value we have configured as threshold.

=over 4

=item * C<currency_code> currency code

=item * C<address> client deposit address

=back

Returns 1 if the address needs to be retained and 0 to a new address generation.

=cut

sub requires_address_retention {
    my ($currency_code, $address) = @_;
    my $db_helper = BOM::CTC::Database->new();

    my $configured_threshold = BOM::Config::CurrencyConfig::get_crypto_new_address_threshold($currency_code);
    # we need to get the sum of amount for all the deposit transactions to this address
    my $address_total_balance_received = $db_helper->get_total_amount_received_by_address($address, $currency_code) // 0;

    return $configured_threshold > $address_total_balance_received ? 1 : 0;
}

=head2 emit_new_address_call

emits new_crypto_address event

=cut

sub emit_new_address_call {

    my ($client_loginid, $retain_address, $address) = @_;

    my $emit = BOM::Platform::Event::Emitter::emit(
        'new_crypto_address',
        {
            loginid        => $client_loginid,
            retain_address => $retain_address,
            address        => $address,
        });

    return $emit;
}

=head2 fraud_address

calls the subroutine which checks the address if
exists in the third party

Note that this works only for BTC at the moment

=over 4

=item * C<address> the address to check

=back

Returns 0 in fail or 1 in success

=cut

sub fraud_address {

    my $data = shift;

    my $address       = $data->{address};
    my $currency_code = $data->{currency_code};

    my $check = _tp_api()->tp_fraud_address($address)->get;

    # if the address is found, then we need to insert it in the database,
    # otherwise, we can either just exit or send a message to the logs
    # that the address is not found on the third party

    my $response = $check->{response_result};
    unless ($response) {
        $log->warnf("An error occured communication with Bitcoinabuse for: %s", $address);
        return 0;
    }
    my $found = $response->{count} > 0 && defined $response->{address} ? 1 : 0;

    if ($found) {
        my $dbic = BOM::CTC::Database->new();
        my $rows = $dbic->insert_fraud_addresses($currency_code, $check->{response_result}->{address}, $check->{response_result}->{count});

        $log->warnf("An error occurred while insterting fraud address in database") unless ($rows);
    }

    return $found;

}

1;
