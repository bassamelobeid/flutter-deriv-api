package BOM::API::Payment::DoughFlow;

## no critic (RequireUseStrict,RequireUseWarnings)

use Moo;
with 'BOM::API::Payment::Role::Plack';

use Scalar::Util qw/blessed/;
use Time::HiRes  qw(gettimeofday tv_interval);
use BOM::API::Payment::DoughFlow::Backend;
use BOM::Database::DataMapper::Payment;
use BOM::API::Payment::Metric;
use BOM::Platform::Event::Emitter;

=head2 _process_doughflow_request

Wrapper around _doughflow_backend so that we don't need to
repeat code to collect metrics.

=cut

sub _process_doughflow_request {
    my ($c, $type) = @_;
    my $param = $c->request_parameters;
    my $tags  = [
        "payment_processor:" . ($param->{payment_processor} // ''),
        "payment_method:" .    ($param->{payment_method}    // ''),
        "language:" .          ($param->{udef1}             // ''),
        "brand:" .             ($param->{udef2}             // ''),
    ];
    my $start            = [Time::HiRes::gettimeofday];
    my $response         = _doughflow_backend($c, $type);
    my $request_millisec = 1000 * Time::HiRes::tv_interval($start);
    BOM::API::Payment::Metric::collect_metric($type, $response, $tags, $request_millisec);
    return $response;
}

=head2 record

Routes requests to the appropriate DoughFlow transaction record method. Currently only GET is supported.

=cut

sub record_GET {
    my $c = shift;

    my $client = $c->user;

    if (my $err = $c->validate('currency_code', 'reference_number')) {
        return $c->status_bad_request('Invalid doughflow record GET request');
    }

    my $currency_code    = $c->request_parameters->{currency_code};
    my $reference_number = $c->request_parameters->{reference_number};

    my $account = $client->default_account
        || return $c->status_bad_request("No account for $client");

    return $c->status_bad_request("No $currency_code account for $client")
        unless $account->currency_code eq $currency_code;

    # Search within account to ensure that this trx_id really belongs to this account.
    my $trx = $account->find_transaction(
        query => [
            id            => $reference_number,
            referrer_type => 'payment'
        ]
    )->[0]
        || do {
        return $c->status_bad_request("Unknown payment transaction number $reference_number");
        };
    my $payment   = $trx->payment;
    my $doughflow = $payment->doughflow
        || return $c->status_bad_request("Not a doughflow transaction $reference_number");

    return {
        reference_number  => $reference_number,
        client_loginid    => $client->loginid,
        currency_code     => $currency_code,
        transaction_date  => $payment->payment_time->iso8601,
        type              => $trx->action_type,
        amount            => $payment->amount,
        trace_id          => $doughflow->trace_id,
        payment_processor => $doughflow->payment_processor,
        created_by        => $doughflow->created_by,
    };
}

=head2 deposit_POST

Receives a request for a DoughFlow deposit record, validates the request, and then attempts to create the deposit record

=cut

sub deposit_POST {
    my $c = shift;
    return _process_doughflow_request($c, 'deposit');
}

=head2 deposit_validate_GET

Receives a request for a DoughFlow deposit record, validates the request

=cut

sub deposit_validate_GET {
    my $c = shift;
    return _process_doughflow_request($c, 'deposit_validate');
}

=head2 withdrawal_validate_GET

Receives a request for a DoughFlow withdrawal record, validates the request, and then attempts to create the withdrawal record

=cut

sub withdrawal_validate_GET {
    my $c = shift;
    return _process_doughflow_request($c, 'withdrawal_validate');
}

=head2 update_payout_POST

Called by Doughflow when a payout is updated.
If new status is 'inprogress', the payout is processed as a withdrawal unless freezing funds are enabled.

=cut

sub update_payout_POST {
    my $c = shift;

    return _process_doughflow_request($c, 'payout_inprogress')
        if ($c->request_parameters->{status} // '') eq 'inprogress';

    return _doughflow_backend($c, 'payout_cancelled')
        if (($c->request_parameters->{status} // '') eq 'cancelled');

    return _doughflow_backend($c, 'payout_rejected')
        if ($c->request_parameters->{status} // '') eq 'rejected';

    return _doughflow_backend($c, 'payout_approved')
        if ($c->request_parameters->{status} // '') eq 'approved';

    return {
        status      => 0,
        description => 'success',
    };
}

=head2 create_payout_POST

Called by Doughflow when a payout is created.
The payout is processed as a withdrawal if freezing funds are enabled.

=cut

sub create_payout_POST {
    my $c = shift;

    BOM::Config::Runtime->instance->app_config->check_for_update();
    return $c->throw(403, 'The cashier is under maintenance, it will be back soon.')
        if BOM::Config::Runtime->instance->app_config->system->suspend->payments_graceful
        and BOM::Config::Runtime->instance->app_config->system->suspend->cashier;

    return _doughflow_backend($c, 'payout_created')
        if ($c->user->is_payout_freezing_funds_enabled);

    return {
        status      => 0,
        description => 'success',
    };
}

=head2 record_failed_deposit_POST

Implements the RecordFailedDeposit Doughflow request.
DoughFlow has provision to notify our platform upon the failure
of customer deposit.
Later we can extend this to notify client about failure.

=cut

sub record_failed_deposit_POST {
    my $c = shift;

    unless (_is_authenticated($c)) {
        return $c->throw(401, 'Authorization required');
    }

    # return success as of now, once we have evaluated all
    # the error messages then we will update this accordingly
    return {
        status      => 0,
        description => 'success',
    };
}

=head2 record_failed_withdrawal_POST

Implements the RecordFailedWithdrawal Doughflow request.
DoughFlow has provision to notify our platform upon the failure
of customer withdrawal.

=cut

sub record_failed_withdrawal_POST {
    my $c = shift;

    unless (_is_authenticated($c)) {
        return $c->throw(401, 'Authorization required');
    }

    # Send event for specific error codes
    my $error_code = $c->request_parameters->{error_code} // '';

    # Shared Payment Method
    if ($error_code eq 'NDB2006') {
        my $client_loginid = $c->request_parameters->{client_loginid} // '';
        my ($shared_loginid) = ($c->request_parameters->{error_desc} // '') =~ m/^Shared\sAccountIdentifier\sPIN:\s(.*)$/;

        BOM::Platform::Event::Emitter::emit(
            'shared_payment_method_found',
            {
                client_loginid => $client_loginid,
                shared_loginid => $shared_loginid,
            });
    }

    return {
        status      => 0,
        description => 'success',
    };
}

=head2 shared_payment_method_POST

Implements the shared_payment_method Doughflow request.

Returns a hashref with the following keys

=over 4

=item * C<status>

Representing status of the request

=item * C<description>

Representing message as per the status of the request

=back

=cut

sub shared_payment_method_POST {
    my $c = shift;

    unless (_is_authenticated($c)) {
        return $c->throw(401, 'Authorization required');
    }

    # <sharedpaymentmethod siteid="1" frontendname="test" client_loginid="CR90000001" shared_loginid="CR90000004,CR90000005,CR90000006" payment_method="VISA" payment_processor="" payment_type="CreditCard" account_identifier="444433******1111" payment_action="deposit" error_code="NDB2006" error_description="Shared AccountIdentifier" />

    # Send event for specific error codes
    my $error_code = $c->request_parameters->{error_code} // '';

    # Shared Payment Method
    if ($error_code eq 'NDB2006') {
        my $client_loginid  = $c->request_parameters->{client_loginid} // '';
        my $shared_loginids = $c->request_parameters->{shared_loginid} // '';

        BOM::Platform::Event::Emitter::emit(
            'shared_payment_method_found',
            {
                client_loginid => $client_loginid,
                shared_loginid => $shared_loginids,
            });
    }

    return {
        status      => 0,
        description => 'success',
    };
}

=head1 INTERNAL METHODS

=head2 _doughflow_backend

Processes all requests to the back-end BOM code for DoughFlow requests.

=cut

sub _doughflow_backend {
    my ($c, $type) = @_;

    return $c->throw(401, 'Authorization required') unless _is_authenticated($c);

    my $new_txn_id = BOM::API::Payment::DoughFlow::Backend->new(
        env  => $c->env,
        type => $type
    )->execute();

    return $new_txn_id if ref($new_txn_id) and $new_txn_id->{status_code};    # Plack::Response
    return $new_txn_id if $type =~ 'validate';

    return {
        status      => 0,
        description => 'success',
        }
        if $type =~ /^(payout_created|payout_inprogress|payout_cancelled|payout_rejected|payout_approved)$/;

    my $location = $c->req->base->clone;
    $location->path('/paymentapi/transaction/payment/doughflow/record/');
    $location->query(
        'client_loginid=' . $c->user->loginid . '&currency_code=' . $c->request_parameters->{'currency_code'} . '&reference_number=' . $new_txn_id);

    return $c->status_created($location->as_string);
}

sub _is_authenticated {
    my $c = shift;

    ## only allow DoughFlow Auth call
    return 0 unless $c->env->{'X-DoughFlow-Authorization-Passed'};

    return 1;
}

no Moo;

1;
