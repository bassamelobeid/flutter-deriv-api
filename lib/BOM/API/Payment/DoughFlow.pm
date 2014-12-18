package BOM::API::Payment::DoughFlow;

## no critic (RequireUseStrict,RequireUseWarnings)

use Moo;
with 'BOM::API::Payment::Role::Plack';

use Try::Tiny;
use Scalar::Util qw/blessed/;
use BOM::API::Payment::DoughFlow::Backend;
use BOM::Utility::Date;
use BOM::Platform::Data::Persistence::DataMapper::Payment;

=head2 record

Routes requests to the appropriate DoughFlow transaction record method. Currently only GET is supported.

=cut

sub record_GET {
    my $c = shift;

    my $log    = $c->env->{log};
    my $client = $c->user;

    ## validate
    if (my $err = $c->validate('currency_code', 'reference_number')) {
        return $c->status_bad_request('Invalid doughflow record GET request');
    }

    my $client_loginid   = $client->loginid;
    my $currency_code    = $c->request_parameters->{currency_code};
    my $reference_number = $c->request_parameters->{reference_number};

    my $payment_datamapper = BOM::Platform::Data::Persistence::DataMapper::Payment->new({
        client_loginid => $client_loginid,
        currency_code  => $currency_code,
    });
    # Can we find a corresponding transaction in this user's account?
    if (not $payment_datamapper->does_account_exist) {
        return $c->throw(500, 'Unable to find account details for client ' . $client_loginid . ', currency ' . $currency_code);
    }

    if (my $payment = $payment_datamapper->get_last_payment_of_account) {
        my $payment_type = ($payment->amount > 0) ? 'deposit' : 'withdrawal';
        my $record = {
            reference_number => $reference_number,
            client_loginid   => $client_loginid,
            currency_code    => $currency_code,
            transaction_date => BOM::Utility::Date->new($payment->payment_time->epoch)->datetime_iso8601,
            type             => $payment_type,
            payment_gateway  => 'doughflow',
        };
        foreach my $field (qw(trace_id payment_processor created_by fee bonus promo_id ip_address transaction_id)) {
            if ($payment->remark =~ /$field=(\S+)\b/) {
                $record->{$field} = $1;
            }
        }
        $log->debug("$client_loginid $currency_code $payment_type got the record successfully");

        return $record;
    } else {
        return $c->throw(404, 'Unknown transaction reference number ' . $reference_number);
    }
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

=head1 INTERNAL METHODS

=head2 _doughflow_backend

Processes all requests to the back-end BOM code for DoughFlow requests.

=cut

sub _doughflow_backend {
    my ($c, $type) = @_;

    ## only allow DoughFlow Auth call
    unless ($c->env->{'X-DoughFlow-Authorization-Passed'}) {
        # check BOM::API::Payment
        return $c->throw(401, 'Authorization required');
    }

    my $new_txn_id = BOM::API::Payment::DoughFlow::Backend->new(
        env  => $c->env,
        type => $type
    )->execute();

    return $new_txn_id if ref($new_txn_id) and $new_txn_id->{status_code};    # Plack::Response
    return $new_txn_id if $type =~ 'validate';

    my $location = $c->req->base->clone;
    $location->path('/transaction/payment/doughflow/record/');
    $location->query(
        'client_loginid=' . $c->user->loginid . '&currency_code=' . $c->request_parameters->{'currency_code'} . '&reference_number=' . $new_txn_id);

    return $c->status_created($location->as_string);
}

no Moo;

1;
