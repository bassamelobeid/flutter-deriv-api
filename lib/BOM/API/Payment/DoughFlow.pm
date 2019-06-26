package BOM::API::Payment::DoughFlow;

## no critic (RequireUseStrict,RequireUseWarnings)

use Moo;
with 'BOM::API::Payment::Role::Plack';

use Try::Tiny;
use Scalar::Util qw/blessed/;
use BOM::API::Payment::DoughFlow::Backend;
use BOM::Database::DataMapper::Payment;

use Log::Any '$new_api_log',
    log_level => 'debug',
    category  => 'new_api_log';
use Log::Any::Adapter;
Log::Any::Adapter->set({category => 'new_api_log'}, 'File', '/var/lib/binary/paymentapi_new_api_calls_trace.log');

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
    return _doughflow_backend($c, 'deposit');
}

=head2 deposit_validate_GET

Receives a request for a DoughFlow deposit record, validates the request

=cut

sub deposit_validate_GET {
    my $c = shift;
    return _doughflow_backend($c, 'deposit_validate');
}

=head2 withdrawal_validate_GET

Receives a request for a DoughFlow withdrawal record, validates the request, and then attempts to create the withdrawal record

=cut

sub withdrawal_validate_GET {
    my $c = shift;
    return _doughflow_backend($c, 'withdrawal_validate');
}

=head2 withdrawal_POST

Receives a request for a DoughFlow withdrawal record, validates the request

=cut

sub withdrawal_POST {
    my $c = shift;
    return _doughflow_backend($c, 'withdrawal');
}

=head2 withdrawal_reversal_POST

Receives a request for a DoughFlow withdrawal reversal record, validates the request, and then attempts to create the withdrawal reversal record

=cut

sub withdrawal_reversal_POST {
    my $c = shift;
    return _doughflow_backend($c, 'withdrawal_reversal');
}

=head2 create_payout_POST, update_payout_POST

The following two subs are placeholders for future implemention of the Doughflow requests CreatePayout and UpdatePayout.
For now they just dump request params to the paymentapi_new_api_calls_trace log.
See https://trello.com/c/10Ex9IyA/8915-8-billmarriott-newdfendpoints-2 for more background.

=cut

sub create_payout_POST {
    my $c = shift;

    _log_new_api_request($c, 'create_payout');

    unless (_is_authenticated($c)) {
        $new_api_log->debugf('create_payout: Authorization required, please check if request has X-DoughFlow-Authorization-Passed header.');
        return $c->throw(401, 'Authorization required');
    }

    # return success as of now, once we have evaluated all
    # the error messages then we will update this accordingly
    return {
        status      => 0,
        description => 'success',
    };
}

sub update_payout_POST {
    my $c = shift;

    _log_new_api_request($c, 'update_payout');

    unless (_is_authenticated($c)) {
        $new_api_log->debugf('update_payout: Authorization required, please check if request has X-DoughFlow-Authorization-Passed header.');
        return $c->throw(401, 'Authorization required');
    }

    # return success as of now, once we have evaluated all
    # the error messages then we will update this accordingly
    return {
        status      => 0,
        description => 'success',
    };
}

=head2 record_failed_deposit_POST

Implements the RecordFailedDeposit Doughflow request.
DoughFlow has provision to notify our platform upon the failure
of customer deposit.
Currently we are just logging to evaluate the data we get, later
we can extend this to notify client about failure.

=cut

sub record_failed_deposit_POST {
    my $c = shift;

    _log_new_api_request($c, 'record_failed_deposit');

    unless (_is_authenticated($c)) {
        $new_api_log->debugf('record_failed_deposit: Authorization required, please check if request has X-DoughFlow-Authorization-Passed header.');
        return $c->throw(401, 'Authorization required');
    }

    # return success as of now, once we have evaluated all
    # the error messages then we will update this accordingly
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

sub _log_new_api_request {
    my ($c, $type) = @_;

    $new_api_log->debugf(
        'Request details: type: %s, timestamp: %s, method: %s and params: %s',
        ($type // ''),
        Date::Utility->new->datetime_yyyymmdd_hhmmss,
        $c->req->method, $c->req->parameters->as_hashref
    );

    return undef;
}

no Moo;

1;
