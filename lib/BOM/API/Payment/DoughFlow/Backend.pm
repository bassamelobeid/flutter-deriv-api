package BOM::API::Payment::DoughFlow::Backend;

## no critic (RequireUseStrict,RequireUseWarnings)

use Moo;
with 'BOM::API::Payment::Role::Plack';

use Guard;
use Try::Tiny;
use Date::Utility;
use Data::Dumper;

use Format::Util::Numbers qw/financialrounding/;

use BOM::Config::Runtime;
use BOM::Database::ClientDB;
use BOM::Database::DataMapper::Payment::DoughFlow;
use BOM::Platform::Client::IDAuthentication;

# one of deposit, withdrawal
has 'type' => (
    is       => 'ro',
    required => 1
);

sub execute {
    my $c      = shift;
    my $log    = $c->env->{log};
    my $client = $c->user;

    if ($c->type eq 'deposit') {
        # if the client uses DF to deposit, unset flag to dont allow them withdrawal through PA
        $client->status->clear_pa_withdrawal_explicitly_allowed;
    }

    if ($c->type eq 'withdrawal_reversal') {
        if (my $err = $c->validate_params) {
            return $c->status_bad_request($err);
        }
    } else {
        my $passed = $c->validate_as_payment;
        $log->debug($c->user->loginid . " validation status for " . $c->type . ": " . Dumper($passed));
        if (ref($passed) and $passed->{status_code}) {    # Plack::Response
            return $passed unless $c->type =~ 'validate';
            # validate
            $passed->{allowed} = 0;
            $passed->{message} = delete $passed->{error};
            return $passed;
        }
        return {allowed => 1} if $c->type =~ 'validate';
    }

    # OK, looks like we're good. Write to the client's
    # currency file if possible
    my $reference_number = $c->write_transaction_line;
    return $reference_number if ref($reference_number) and $reference_number->{status_code};    # Plack::Response

    # This is what everyone wants
    return $reference_number;
}

sub comment {
    my $c = shift;

    my %fields;
    my @vars = qw/payment_processor/;
    push @vars, qw/transaction_id created_by/ if $c->type eq 'deposit';                         # ip_address
    foreach my $var (@vars) {
        $fields{$var} = $c->request_parameters->{$var};
    }

    my $line = "DoughFlow " . $c->type . " trace_id=" . $c->request_parameters->{'trace_id'};

    # Put all of the additional comment fields in alphabetic order after the trace ID
    my @non_empty_fields = (sort { $a cmp $b } (grep { defined($fields{$_}) and length($fields{$_}) } (keys %fields)));
    if (@non_empty_fields) {
        $line .= ' ' . join(' ', map { $_ . '=' . $fields{$_} } @non_empty_fields);
    }
    return $line;
}

sub validate_params {
    my $c   = shift;
    my $log = $c->env->{log};

    my $type   = $c->type;
    my $method = $c->req->method;

    my @required = qw/reference_number currency_code/;
    if ($method eq 'POST' || $type eq 'deposit_validate' || $type eq 'withdrawal_validate') {
        @required = qw/amount currency_code payment_processor/;
        push @required, 'trace_id' if $method eq 'POST';
    }

    $log->debug("required params for $method / $type are " . join('/', @required));

    return $c->validate(@required);
}

sub validate_as_payment {
    my $c   = shift;
    my $log = $c->env->{log};

    if (my $err = $c->validate_params) {
        return $c->status_bad_request($err);
    }

    if (BOM::Config::Runtime->instance->app_config->system->suspend->payments) {
        return $c->throw(403, 'Payments are suspended.');
    }

    my $client = $c->user;
    my $action =
          ($c->type =~ /deposit/i)    ? 'deposit'
        : ($c->type =~ /withdrawal/i) ? 'withdraw'
        :                               return 1;

    my $currency      = $c->request_parameters->{currency_code};
    my $signed_amount = $c->request_parameters->{amount};
    $signed_amount *= -1 if $action eq 'withdraw';

    my $err;
    try {
        $client->set_default_account($currency);
        $client->validate_payment(
            currency    => $currency,
            amount      => $signed_amount,
            action_type => $action,
        );
    }
    catch {
        $err = $_;
    };
    return $c->throw(403, $err) if $err;

    $log->debug("$action validation passed");

    return 1;
}

sub write_transaction_line {
    my $c   = shift;
    my $log = $c->env->{log};

    my $client = $c->user;

    # Lock the customer's account
    my $client_db = BOM::Database::ClientDB->new({client_loginid => $client->loginid});
    my $freeze_status = $client_db->freeze;

    # unfreeze on exit no matter it's succeed or not
    scope_guard {
        # Unlock the customer's account
        $client_db->unfreeze;
    };

    return $c->throw(403, "Unable to lock the account. Please try again after one minute.") unless $freeze_status;

    my $currency_code  = $c->request_parameters->{currency_code};
    my $transaction_id = $c->request_parameters->{transaction_id};
    my $trace_id       = $c->request_parameters->{trace_id};
    my $amount         = $c->request_parameters->{amount};
    my $processor      = $c->request_parameters->{payment_processor};

    if (
        my $rejection = $c->check_predicates({
                currency_code  => $currency_code,
                transaction_id => $transaction_id,
                trace_id       => $trace_id,
                amount         => $amount,
                processor      => $processor,
            }))
    {
        return $c->status_bad_request($rejection);
    }

    my $bonus = $c->request_parameters->{bonus} || 0;
    my $fee   = $c->request_parameters->{fee}   || 0;

    my $payment_processor = $c->request_parameters->{payment_processor};
    my $created_by        = $c->request_parameters->{created_by};
    my $ip_address        = $c->request_parameters->{ip_address};

    my %payment_args = (
        currency          => $currency_code,
        amount            => $amount,
        remark            => $c->comment,
        staff             => $client->loginid,
        created_by        => $created_by,
        trace_id          => $trace_id,
        payment_processor => $payment_processor,
        transaction_id    => $transaction_id,
        ip_address        => $ip_address,
        payment_fee       => $fee,
    );

    # Write the payment transaction
    my ($trx, $fdp);

    if ($c->type eq 'deposit') {
        $fdp = $client->is_first_deposit_pending;
        $trx = $client->payment_doughflow(%payment_args);

        # Social responsibility checks for MLT/MX clients
        if ($client->landing_company->social_responsibility_check_required) {
            $client->increment_social_responsibility_values({
                deposit_amount => $amount,
                deposit_count  => 1
            });
        }

    } elsif ($c->type eq 'withdrawal') {
        # Don't allow balances to ever go negative! Include any fee in this test.
        my $balance = $client->default_account->balance;
        if ($amount + $fee > $balance) {
            my $plusfee = $fee ? " plus fee $fee" : '';
            return $c->status_bad_request(
                "Requested withdrawal amount $currency_code $amount$plusfee exceeds client balance $currency_code $balance");
        }
        $payment_args{amount} = -$amount;
        $trx = $client->payment_doughflow(%payment_args);
    } elsif ($c->type eq 'withdrawal_reversal') {
        if ($bonus or $fee) {
            return $c->status_bad_request('Bonuses and fees are not allowed for withdrawal reversals');
        }
        $trx = $client->payment_doughflow(%payment_args);
    }

    BOM::Platform::Client::IDAuthentication->new(client => $client)->run_authentication if $fdp;

    if ($fee) {
        $log->debug($c->type . " fee transaction complete, trx id " . $trx->fee_transaction_id);
    }

    $log->debug($c->type . " transaction complete, trx id " . $trx->transaction_id);
    return $trx->transaction_id;
}

sub check_predicates {
    my $c    = shift;
    my $args = shift;

    my $trace_id      = $args->{'trace_id'};
    my $amount        = $args->{'amount'};
    my $currency_code = $args->{'currency_code'};
    my $processor     = $args->{'processor'};

    # Detecting duplicates for DoughFlow is simple; it'll be
    # any transaction with an identical type (deposit/withdrawal)
    # and trace id
    my $doughflow_datamapper = BOM::Database::DataMapper::Payment::DoughFlow->new({
        client_loginid => $c->user->loginid,
        currency_code  => $currency_code
    });

    my $rejection;
    if ($c->type eq 'withdrawal_reversal') {
        # In order to process this withdrawal reversion, we must first find a currency
        # file entry that describes the withdrawal being reversed. That entry must be
        # be a 'DoughFlow withdrawal' and must have the same trace_id as the one sent
        # with the withdrawal reversal request.

        my $match_count = $doughflow_datamapper->get_doughflow_withdrawal_count_by_trace_id($trace_id);

        return
              'A withdrawal reversal was requested for DoughFlow trace ID '
            . $trace_id
            . ', but no corresponding original withdrawal could be found with that trace ID'
            unless $match_count;

        return
              'A withdrawal reversal was requested for DoughFlow trace ID '
            . $trace_id
            . ', but multiple corresponding original withdrawals were found with that trace ID '
            if ($match_count > 1);

        my ($amt, $trace_amt) = (
            financialrounding('amount', $currency_code, $amount),
            financialrounding('amount', $currency_code, $doughflow_datamapper->get_doughflow_withdrawal_amount_by_trace_id($trace_id)));
        return
              'A withdrawal reversal request for DoughFlow trace ID '
            . $trace_id
            . ' was made in the amount of '
            . $currency_code . ' '
            . $amt
            . ', but this does not match the original DoughFlow withdrawal request amount'
            if ($amt != $trace_amt);
    }

    my $transaction_id = $args->{transaction_id} // '';
    if (
        $doughflow_datamapper->is_duplicate_payment({
                payment_processor => $processor,
                transaction_type  => $c->type,
                trace_id          => $trace_id,
                transaction_id    => $transaction_id,
            }))
    {
        $rejection =
              "Detected duplicate transaction ["
            . $c->comment
            . "] while processing request for "
            . $c->type
            . " with trace id "
            . $trace_id
            . " and transaction id "
            . $transaction_id;
    }

    return $rejection;
}

no Moo;

1;
