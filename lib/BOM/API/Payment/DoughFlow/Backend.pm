package BOM::API::Payment::DoughFlow::Backend;

## no critic (RequireUseStrict,RequireUseWarnings)

use Moo;
with 'BOM::API::Payment::Role::Plack';

use Guard;
use Syntax::Keyword::Try;
use Date::Utility;
use Data::Dumper;
use Text::Trim;

use Format::Util::Numbers qw/financialrounding/;

use BOM::Config::Runtime;
use BOM::Database::ClientDB;
use BOM::Database::DataMapper::Payment::DoughFlow;
use BOM::Platform::Event::Emitter;
use BOM::Platform::Context qw (localize);
use BOM::Platform::Context::Request;

has 'type' => (
    is       => 'ro',
    required => 1
);

# maps our internal type names to the transaction type names we store in the db
my %type_mapping = (
    payout_created    => 'withdrawal_hold',
    payout_inprogress => 'withdrawal',
    payout_rejected   => 'withdrawal_reversal',
    payout_cancelled  => 'withdrawal_reversal',
);

=head2 _handle_qualifying_payments

Handle the qualifying payments regulation check for clients that requires it.

=cut

sub _handle_qualifying_payments {
    my ($client, $amount, $action) = @_;

    return $client->increment_qualifying_payments({
        amount => $amount,
        action => $action
    });
}

sub execute {
    my $c      = shift;
    my $log    = $c->env->{log};
    my $client = $c->user;

    my $args = {};
    $args->{language}   = $c->request_parameters->{udef1} if $c->request_parameters->{udef1};
    $args->{brand_name} = $c->request_parameters->{udef2} if $c->request_parameters->{udef2};

    my $r = BOM::Platform::Context::Request->new($args);
    BOM::Platform::Context::request($r);

    if ($c->type eq 'deposit') {
        # if the client uses DF to deposit, unset flag to dont allow them withdrawal through PA
        $client->status->clear_pa_withdrawal_explicitly_allowed;
    }

    if ($c->type eq 'payout_rejected') {
        if (my $err = $c->validate_params) {
            return $c->status_bad_request($err);
        }
    } else {
        my $passed = $c->validate_as_payment;
        $log->debug($c->user->loginid . " validation status for " . $c->type . ": " . Dumper($passed));
        if (ref($passed) and $passed->{status_code}) {    # Plack::Response
            return $passed unless $c->type =~ 'validate';
            # validate
            return {
                allowed => 0,
                message => $passed->{error},
            };
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
    my @vars = qw/payment_processor payment_method/;
    push @vars, qw/transaction_id created_by/ if $c->type eq 'deposit';                         # ip_address
    foreach my $var (@vars) {
        $fields{$var} = $c->request_parameters->{$var};
    }

    my $type = $type_mapping{$c->type} // $c->type;
    my $line = "DoughFlow $type trace_id=" . $c->request_parameters->{'trace_id'};

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

    $c->request_parameters->{trace_id} = trim($c->request_parameters->{trace_id}) if $c->request_parameters->{trace_id};

    my @required = qw/reference_number currency_code/;
    if ($method eq 'POST' || $type eq 'deposit_validate' || $type eq 'withdrawal_validate') {
        @required = qw/amount currency_code/;
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
          $c->type =~ /^(deposit|deposit_validate)$/              ? 'deposit'
        : $c->type =~ /^(payout_inprogress|withdrawal_validate)$/ ? 'withdraw'
        :                                                           return 1;

    my $currency      = $c->request_parameters->{currency_code};
    my $signed_amount = $c->request_parameters->{amount};
    $signed_amount *= -1 if $action eq 'withdraw';

    try {
        $client->set_default_account($currency);
        $client->validate_payment(
            currency    => $currency,
            amount      => $signed_amount,
            action_type => $action,
        );
    } catch {
        my $err = $@;

        return $c->throw(403, $err) if $err;
    }

    $log->debug("$action validation passed");

    return 1;
}

sub write_transaction_line {
    my $c   = shift;
    my $log = $c->env->{log};

    my $client = $c->user;

    my $currency_code      = $c->request_parameters->{currency_code};
    my $transaction_id     = $c->request_parameters->{transaction_id};
    my $trace_id           = $c->request_parameters->{trace_id};
    my $amount             = $c->request_parameters->{amount};
    my $payment_processor  = $c->request_parameters->{payment_processor} // '';
    my $payment_method     = $c->request_parameters->{payment_method};
    my $payment_type       = $c->request_parameters->{payment_type} // '';
    my $account_identifier = $c->request_parameters->{account_identifier} // '';

    my $doughflow_datamapper = BOM::Database::DataMapper::Payment::DoughFlow->new({
        client_loginid => $c->user->loginid,
        currency_code  => $currency_code
    });

    # this probably is not going to be necessary most of the time
    # but this check for each payout at this point is the safest way to do it
    if ($c->type eq 'payout_inprogress') {
        # if the payout has been created when freezing funds were enabled, the client has been already debited
        # return 200 and allow the process to continue, no further processing is needed
        if (
            $doughflow_datamapper->is_duplicate_payment({
                    transaction_type => $type_mapping{payout_created},
                    trace_id         => $trace_id,
                    transaction_id   => $transaction_id,
                }))
        {
            return {
                status      => 0,
                description => 'success'
            };
        }
    }

    if ($c->type eq 'payout_cancelled') {
        my $match_count = $doughflow_datamapper->get_doughflow_withdrawal_count_by_trace_id($trace_id);

        # if the client hasn't been debited yet
        return {
            status      => 0,
            description => 'success'
            }
            if (
            $match_count == 0 ||    # the client hasn't been debited yet
            $match_count == 2       # the payment has been already reversed
            );
    }

    if (
        my $rejection = $c->check_predicates({
                currency_code     => $currency_code,
                transaction_id    => $transaction_id,
                trace_id          => $trace_id,
                amount            => $amount,
                payment_processor => $payment_processor,
            }))
    {
        return $c->status_bad_request($rejection);
    }

    my $bonus = $c->request_parameters->{bonus}                                    || 0;
    my $fee   = $c->request_parameters->{fee} && $c->request_parameters->{fee} + 0 || 0;

    my $created_by = $c->request_parameters->{created_by};
    my $ip_address = $c->request_parameters->{ip_address};

    my %payment_args = (
        currency          => $currency_code,
        amount            => $amount,
        remark            => $c->comment,
        staff             => $client->loginid,
        created_by        => $created_by,
        trace_id          => $trace_id,
        payment_processor => $payment_processor,
        payment_method    => $payment_method,
        transaction_id    => $transaction_id,
        ip_address        => $ip_address,
        payment_fee       => $fee,
        transaction_type  => $type_mapping{$c->type} // $c->type,
    );

    # Write the payment transaction
    my $trx;
    my $event_args = {
        loginid        => $client->loginid,
        trace_id       => $trace_id,
        amount         => $amount,
        payment_fee    => $fee,
        currency       => $currency_code,
        payment_method => $payment_method,
    };

    if ($c->type eq 'deposit') {
        # should be executed before saving the payment in the database
        my $is_first_deposit = $client->is_first_deposit_pending;

        $trx = $client->payment_doughflow(%payment_args);

        BOM::Platform::Event::Emitter::emit(
            'payment_deposit',
            {
                $event_args->%*,
                transaction_id     => $trx->{id},
                is_first_deposit   => $is_first_deposit,
                account_identifier => $account_identifier,
                payment_processor  => $payment_processor,    # only deposit has payment_processor
                payment_type       => $payment_type,
            }) if ($trx);

        # Social responsibility checks for MLT/MX clients
        $client->increment_social_responsibility_values({net_deposits => $amount})
            if ($client->landing_company->social_responsibility_check_required);

        _handle_qualifying_payments($client, $amount, $c->type) if $client->landing_company->qualifying_payment_check_required;
    } elsif ($c->type =~ /^(payout_created|payout_inprogress)$/) {
        # Don't allow balances to ever go negative! Include any fee in this test.
        my $balance = $client->default_account->balance;
        if ($amount + $fee > $balance) {
            my $plusfee = $fee ? " plus fee $fee" : '';
            return $c->status_bad_request(
                "Requested withdrawal amount $amount$plusfee $currency_code exceeds client balance $balance $currency_code");
        }

        $payment_args{amount} = -$amount;
        $trx = $client->payment_doughflow(%payment_args);
        BOM::Platform::Event::Emitter::emit('payment_withdrawal', {$event_args->%*, transaction_id => $trx->{id}}) if ($trx);

        # Social responsibility checks for MLT/MX clients
        $client->increment_social_responsibility_values({
                net_deposits => -$amount,
            }) if ($client->landing_company->social_responsibility_check_required);

        _handle_qualifying_payments($client, $amount, $c->type) if $client->landing_company->qualifying_payment_check_required;
    } elsif ($c->type =~ /^(payout_cancelled|payout_rejected)$/) {
        if ($bonus) {
            return $c->status_bad_request('Bonuses are not allowed for withdrawal reversals');
        }
        $payment_args{payment_fee} = -$fee;
        $trx = $client->payment_doughflow(%payment_args);
        BOM::Platform::Event::Emitter::emit('payment_withdrawal_reversal', {$event_args->%*, transaction_id => $trx->{id}}) if ($trx);
    }

    if ($fee) {
        $log->debug($c->type . " fee transaction complete, trx id " . $trx->fee_transaction_id);
    }

    $log->debug($c->type . " transaction complete, trx id " . $trx->transaction_id);
    return $trx->transaction_id;
}

sub check_predicates {
    my $c    = shift;
    my $args = shift;

    my $trace_id          = $args->{'trace_id'};
    my $amount            = $args->{'amount'};
    my $currency_code     = $args->{'currency_code'};
    my $payment_processor = $args->{'payment_processor'};

    # Detecting duplicates for DoughFlow is simple; it'll be
    # any transaction with an identical type (deposit/withdrawal)
    # and trace id
    my $doughflow_datamapper = BOM::Database::DataMapper::Payment::DoughFlow->new({
        client_loginid => $c->user->loginid,
        currency_code  => $currency_code
    });

    if ($c->type =~ /^(payout_cancelled|payout_rejected)$/) {
        # In order to process this withdrawal reversion, we must first find a currency
        # file entry that describes the withdrawal being reversed. That entry must be
        # be a 'DoughFlow withdrawal' and must have the same trace_id as the one sent
        # with the withdrawal reversal request.

        my $match_count = $doughflow_datamapper->get_doughflow_withdrawal_count_by_trace_id($trace_id);

        return
            sprintf(
            'A withdrawal reversal was requested for DoughFlow trace ID %d, but no corresponding original withdrawal could be found with that trace ID',
            $trace_id)
            unless $match_count;

        return
            sprintf(
            'A withdrawal reversal was requested for DoughFlow trace ID %d, but multiple corresponding original withdrawals were found with that trace ID',
            $trace_id)
            if ($match_count > 1);

        my ($amt, $trace_amt) = (
            financialrounding('amount', $currency_code, $amount),
            financialrounding('amount', $currency_code, $doughflow_datamapper->get_doughflow_withdrawal_amount_by_trace_id($trace_id)));

        return
            sprintf(
            'A withdrawal reversal request for DoughFlow trace ID %d was made in the amount of %s %s, but this does not match the original DoughFlow withdrawal request amount',
            $trace_id, $currency_code, $amt)
            if ($amt != $trace_amt);
    }

    my $transaction_id = $args->{transaction_id} // '';
    my $type           = $type_mapping{$c->type} // $c->type;

    if (
        $doughflow_datamapper->is_duplicate_payment({
                payment_processor => $payment_processor,
                transaction_type  => $type,
                trace_id          => $trace_id,
                transaction_id    => $transaction_id,
            }))
    {
        return sprintf('Detected duplicate transaction [%s] while processing request for %s with trace id %s and transaction id %s',
            $c->comment, $type, $trace_id, $transaction_id);
    }

    return;
}

no Moo;

1;
