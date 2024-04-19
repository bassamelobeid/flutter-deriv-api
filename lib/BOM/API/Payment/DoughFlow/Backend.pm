package BOM::API::Payment::DoughFlow::Backend;

## no critic (RequireUseStrict,RequireUseWarnings)

use Moo;
with 'BOM::API::Payment::Role::Plack';

use Guard;
use Syntax::Keyword::Try;
use Date::Utility;
use Data::Dumper;
use Text::Trim;
use Digest::SHA qw/sha256_hex/;

use Format::Util::Numbers qw/financialrounding/;

use BOM::Config::Runtime;
use BOM::Database::ClientDB;
use BOM::Database::DataMapper::Payment::DoughFlow;
use BOM::Platform::Context qw(localize request);
use BOM::Platform::Context::Request;
use BOM::Platform::Utility qw(error_map);
use BOM::Platform::Client::AntiFraud;
use BOM::Rules::Engine;

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

my %custom_errors = do {
    ## no critic(TestingAndDebugging::ProhibitNoWarnings)
    no warnings 'redefine';
    local *localize = sub { die "you can't use params with this dummy localize() call" if @_ > 1; shift };
    (
        SelfExclusionLimitExceeded => {
            message => localize(
                "This deposit will cause your account balance to exceed your limit of [_1] [_2]. To proceed with this deposit, please <a href=\"[_3]\">adjust your self exclusion settings</a>."
            ),
            link => 'self_exclusion_url',
        },
        BalanceExceeded => {
            message => localize("This deposit will cause your account balance to exceed your <a href=\"[_3]\">account limit</a> of [_1] [_2]."),
            link    => 'account_limits_url',
        },
        WithdrawalLimit => {
            message => localize(
                "We're unable to process your withdrawal request because it exceeds the limit of [_1] [_2]. Please <a href=\"[_3]\">authenticate your account</a> before proceeding with this withdrawal."
            ),
            link => 'authentication_url'
        },
        WithdrawalLimitReached => {
            message => localize(
                "You've reached the maximum withdrawal limit of [_1] [_2]. Please <a href=\"[_3]\">authenticate your account</a> before proceeding with this withdrawal."
            ),
            link => 'authentication_url'
        },
    );
};

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
        my $account_currency = $client->currency;
        my $deposit_currency = $c->request_parameters->{currency_code};
        if ($account_currency ne $deposit_currency) {
            return $c->status_bad_request(
                "Deposit currency mismatch, client account is in $account_currency, but the deposit is in $deposit_currency");
        }
        # if the client uses DF to deposit, unset flag to dont allow them withdrawal through PA
        $client->clear_status_and_sync_to_siblings('pa_withdrawal_explicitly_allowed');
        $client->status->clear_deposit_attempt;
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

=head2 _generate_payment_error_message

Generates a localized error message from the error returned by C<payment_validation> 
and also sets the error_code field for the Datadog reporting unless it is set.

=cut

sub _generate_payment_error_message {
    my $error = shift;
    my $c     = shift;

    # no need to process unknown erros
    return $error unless ref($error) eq 'HASH';

    my $code   = $error->{code} // 'InternalCashierError';
    my $params = $error->{params};
    # Set the error code if it is absent
    $c->error_code($code) unless $c->error_code;

    my $message = error_map->{$code};
    if ($custom_errors{$code}) {
        $message = $custom_errors{$code}->{message};
        my $link_name = $custom_errors{$code}->{link};
        push @$params, request()->brand->$link_name;
    } else {
        return $error->{message_to_client};
    }

    return localize($message, @$params);
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

    BOM::Config::Runtime->instance->app_config->check_for_update();
    my $suspend_flags = (BOM::Config::Runtime->instance->app_config->system->suspend->payments_graceful
            and BOM::Config::Runtime->instance->app_config->system->suspend->cashier);
    my $graceful_suspend_flag = ($c->type =~ /^(deposit_validate|withdrawal_validate)$/ and $suspend_flags);
    return $c->throw(403, 'The cashier is under maintenance, it will be back soon.') if $graceful_suspend_flag;

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
        # deposits are not validated becaause we already did so for deposit_validate
        # and at this point we are holding the client funds from payment processor
        $client->validate_payment(
            currency           => $currency,
            amount             => $signed_amount,
            action_type        => $action,
            payment_type       => 'doughflow',
            rule_engine        => BOM::Rules::Engine->new(client => $client),
            skip_cashier_check => $suspend_flags,
        ) unless $c->type eq 'deposit';

        if ($action eq 'deposit' and not $client->status->age_verification) {
            my $processor = $c->request_parameters->{payment_processor} // '';

            my $doughflow_datamapper = BOM::Database::DataMapper::Payment::DoughFlow->new({client_loginid => $client->loginid});

            my ($doughflow_method) = $doughflow_datamapper->get_doughflow_methods({
                    processor => $processor,
                    method    => ''            # we do not expect payment_method to be sent for deposit_validate
                })->@*;

            my $msg;

            if ($doughflow_method and $doughflow_method->{deposit_poi_required}) {
                $client->status->upsert('allow_document_upload', 'system', "Deposit attempted with method requiring POI ($processor)");
                $c->error_code('DepositPoiRequired');
                $log->warn("$action validation failed as client didn't performed verification process");
                $msg = localize(
                    "To use this method for deposits, we'll need to verify your identity. Click [_1] here[_2] to start the verification process, or choose another deposit method.",
                    '<a href="' . request()->brand->authentication_url({language => request()->language}) . '">',
                    '</a>'
                );
            } elsif ($client->status->df_deposit_requires_poi) {
                if (my $payment_type = $c->request_parameters->{payment_type}) {
                    my $antifraud = BOM::Platform::Client::AntiFraud->new(client => $client);

                    try {
                        if ($antifraud->df_cumulative_total_by_payment_type($payment_type)) {
                            $c->error_code('DepositLimitReached');
                            $log->warn("$action validation failed as client hit his deposit limit");
                            $msg = localize(
                                "You've hit the deposit limit, we'll need to verify your identity. Click [_1] here[_2] to start the verification process.",
                                '<a href="' . request()->brand->authentication_url({language => request()->language}) . '">',
                                '</a>'
                            );
                        }
                    } catch ($e) {
                        $log->warn(sprintf('Failed to check for deposit limits of the client %s: %s', $client->loginid, $e));
                    }
                }
            }

            die "$msg\n" if $msg;
        }
    } catch ($err) {
        return $c->throw(403, _generate_payment_error_message($err, $c));
    }

    $log->debug("$action validation passed");
    return 1;
}

sub write_transaction_line {
    my $c   = shift;
    my $log = $c->env->{log};

    my $client = $c->user;

    my $currency_code     = $c->request_parameters->{currency_code};
    my $transaction_id    = $c->request_parameters->{transaction_id};
    my $trace_id          = $c->request_parameters->{trace_id};
    my $amount            = $c->request_parameters->{amount};
    my $payment_processor = $c->request_parameters->{payment_processor} // '';
    my $payment_method    = $c->request_parameters->{payment_method};
    my $payment_type      = $c->request_parameters->{payment_type};
    my $account_identifier;

    if (defined $c->request_parameters->{account_identifier}) {
        $account_identifier = sha256_hex($c->request_parameters->{account_identifier});
    }

    my $doughflow_datamapper = BOM::Database::DataMapper::Payment::DoughFlow->new({
        client_loginid => $c->user->loginid,
        currency_code  => $currency_code
    });

    if ($c->type eq 'payout_approved') {
        # Payout request with freezing funds is done
        $client->decr_df_payouts_count($trace_id);

        return {
            status      => 0,
            description => 'success'
        };
    }
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
        currency                   => $currency_code,
        amount                     => $amount,
        remark                     => $c->comment,
        staff                      => $client->loginid,
        created_by                 => $created_by,
        trace_id                   => $trace_id,
        payment_processor          => $payment_processor,
        payment_method             => $payment_method,
        transaction_id             => $transaction_id,
        ip_address                 => $ip_address,
        payment_fee                => $fee,
        transaction_type           => $type_mapping{$c->type} // $c->type,
        df_payment_type            => $payment_type,
        payment_account_identifier => $account_identifier,
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

    try {
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
                    gateway_code       => 'doughflow',
                }) if ($trx);

            # Social responsibility checks for MLT/MX clients
            $client->increment_social_responsibility_values({net_deposits => $amount})
                if ($client->landing_company->social_responsibility_check && $client->landing_company->social_responsibility_check eq 'required');

            _handle_qualifying_payments($client, $amount, $c->type) if $client->landing_company->qualifying_payment_check_required;
        } elsif ($c->type =~ /^(payout_created|payout_inprogress)$/) {
            # Don't allow balances to ever go negative! Include any fee in this test.
            my $balance = $client->default_account->balance;
            if (financialrounding('amount', $currency_code, $amount + $fee) > financialrounding('amount', $currency_code, $balance)) {
                my $plusfee = $fee ? " plus fee $fee" : '';
                return $c->status_bad_request(
                    "Requested withdrawal amount $amount$plusfee $currency_code exceeds client balance $balance $currency_code");
            }

            $payment_args{amount} = -$amount;
            $trx = $client->payment_doughflow(%payment_args);

            BOM::Platform::Event::Emitter::emit(
                'payment_withdrawal',
                {
                    $event_args->%*,
                    gateway_code   => 'doughflow',
                    transaction_id => $trx->{id}}) if ($trx);

            # Social responsibility checks for MLT/MX clients
            $client->increment_social_responsibility_values({
                    net_deposits => -$amount,
                }) if ($client->landing_company->social_responsibility_check && $client->landing_company->social_responsibility_check eq 'required');

            # Payout request with freezing funds need to be counted
            if ($client->is_payout_freezing_funds_enabled) {
                $client->incr_df_payouts_count($trace_id);
            }
            _handle_qualifying_payments($client, $amount, $c->type) if $client->landing_company->qualifying_payment_check_required;

        } elsif ($c->type =~ /^(payout_cancelled|payout_rejected)$/) {
            if ($bonus) {
                return $c->status_bad_request('Bonuses are not allowed for withdrawal reversals');
            }
            $payment_args{payment_fee} = -$fee;
            $trx = $client->payment_doughflow(%payment_args);

            # Payout request with freezing funds is done
            $client->decr_df_payouts_count($trace_id);

            BOM::Platform::Event::Emitter::emit('payment_withdrawal_reversal', {$event_args->%*, transaction_id => $trx->{id}}) if ($trx);
        }
    } catch ($e) {
        # BI106 is duplicate trace_id + transaction_type
        return $c->status_bad_request($e->[1]) if ref $e eq 'ARRAY' and $e->[0] eq 'BI106';
        die $e;
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
