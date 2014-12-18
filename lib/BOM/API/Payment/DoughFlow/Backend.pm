package BOM::API::Payment::DoughFlow::Backend;

## no critic (RequireUseStrict,RequireUseWarnings)

use Moo;
with 'BOM::API::Payment::Role::Plack';

use BOM::Platform::Runtime;
use BOM::Platform::Transaction;
use BOM::Utility::Date;
use Guard;
use BOM::Platform::Data::Persistence::DataMapper::Payment::DoughFlow;
use BOM::Platform::Client::Utility;
use Try::Tiny;

# one of deposit, withdrawal
has 'type' => (
    is       => 'ro',
    required => 1
);

sub execute {
    my $c      = shift;
    my $log    = $c->env->{log};
    my $client = $c->user;

    if ($c->type =~ 'deposit') {

        # when client deposits using DF, restrict withdrawals to payment agents
        my $today = BOM::Utility::Date->today();
        if (   !$client->payment_agent_withdrawal_expiration_date
            || !BOM::Utility::Date->new($client->payment_agent_withdrawal_expiration_date)->is_same_as($today))
        {
            $client->payment_agent_withdrawal_expiration_date($today->date_yyyymmdd);
            $client->save();
        }
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

    if (BOM::Platform::Runtime->instance->app_config->system->suspend->system) {
        return $c->throw(403, 'Client activity disabled at this time');
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
            )
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
    if (not BOM::Platform::Transaction->freeze_client($client->loginid)) {
        return $c->throw(403, "Unable to lock customer account; please contact customer support");
    }
    ## unfreeze on exit no matter it's succeed or not
    scope_guard {
        # Unlock the customer's account
        BOM::Platform::Transaction->unfreeze_client($client->loginid);
    };

    if (my $rejection = $c->check_predicates()) {
        return $c->status_bad_request($rejection);
    }

    my $bonus = $c->request_parameters->{bonus} || 0;
    my $fee   = $c->request_parameters->{fee}   || 0;

    my $currency_code     = $c->request_parameters->{currency_code};
    my $amount            = $c->request_parameters->{amount};
    my $staff             = $c->request_parameters->{staff};
    my $trace_id          = $c->request_parameters->{trace_id};
    my $payment_processor = $c->request_parameters->{payment_processor};
    my $transaction_id    = $c->request_parameters->{transaction_id};
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
    );

    # Write the payment transaction
    my $trx;

    if ($c->type eq 'deposit') {
        $trx = $client->payment_doughflow(%payment_args);
    } elsif ($c->type eq 'withdrawal') {
        # Don't allow balances to ever go negative! Include any fee in this test.
        my $balance = $client->default_account->load->balance;
        if ($amount + $fee > $balance) {
            my $plusfee = $fee ? " plus fee $fee" : '';
            return $c->status_bad_request(
                "Requested withdrawal amount $currency_code $amount$plusfee exceeds client balance $currency_code $balance");
        }
        $trx = $client->payment_doughflow(%payment_args, amount => sprintf("%0.2f", -$amount));
    } elsif ($c->type eq 'withdrawal_reversal') {
        if ($bonus or $fee) {
            return $c->status_bad_request('Bonuses and fees are not allowed for withdrawal reversals');
        }
        $trx = $client->payment_doughflow(%payment_args);
    }

    if ($fee) {
        my $fee_trx = $client->payment_payment_fee(
            %payment_args,
            amount => -$fee,
            remark => $c->fee_comment($trx->id),
        );
        $log->debug($c->type . " fee transaction complete, trx id " . $fee_trx->id);
    }

    $log->debug($c->type . " transaction complete, trx id " . $trx->id);
    return $trx->id;
}

sub check_predicates {
    my $c = shift;

    my $trace_id      = $c->request_parameters->{'trace_id'};
    my $amount        = $c->request_parameters->{'amount'};
    my $currency_code = $c->request_parameters->{'currency_code'};

    # Detecting duplicates for DoughFlow is simple; it'll be
    # any transaction with an identical type (deposit/withdrawal)
    # and trace id
    my $doughflow_datamapper = BOM::Platform::Data::Persistence::DataMapper::Payment::DoughFlow->new({
        client_loginid => $c->user->loginid,
        currency_code  => $currency_code,
    });

    my $rejection;
    if ($c->type eq 'withdrawal_reversal') {
        # In order to process this withdrawal reversion, we must first find a currency
        # file entry that describes the withdrawal being reversed. That entry must be
        # be a 'DoughFlow withdrawal' and must have the same trace_id as the one sent
        # with the withdrawal reversal request.
        my $trace_regex = 'trace_id=' . $trace_id;

        my $match_count = $doughflow_datamapper->get_doughflow_withdrawal_count_by_trace_id($trace_id);
        if (!$match_count) {
            $rejection =
                  'A withdrawal reversal was requested for DoughFlow trace ID '
                . $trace_id
                . ', but no corresponding original withdrawal could be found with that trace ID';
        } elsif ($match_count > 1) {
            $rejection =
                  'A withdrawal reversal was requested for DoughFlow trace ID '
                . $trace_id
                . ', but multiple corresponding original withdrawals were found with that trace ID ';
        } elsif (sprintf("%0.2f", $doughflow_datamapper->get_doughflow_withdrawal_amount_by_trace_id($trace_id)) != sprintf("%0.2f", $amount)) {
            $rejection =
                  'A withdrawal reversal request for DoughFlow trace ID '
                . $trace_id
                . ' was made in the amount of '
                . $currency_code . ' '
                . sprintf("%0.2f", $amount)
                . ', but this does not match the original DoughFlow withdrawal request amount';
        }

        return $rejection if $rejection;
    }

    my $comment = $c->comment;
    if ($doughflow_datamapper->is_duplicate_payment_by_remark($comment)) {
        $rejection = "Detected duplicate transaction [" . $comment . "] while processing request for " . $c->type . " with trace id " . $trace_id;
    }

    return $rejection;
}

no Moo;

1;
