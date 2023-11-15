package BOM::Platform::CryptoCashier::API;

=head1 NAME

BOM::Platform::CryptoCashier::API

=head1 DESCRIPTION

This module contains the helpers for calling our crypto cashier services.

=cut

use strict;
use warnings;

use DataDog::DogStatsd::Helper;
use JSON::MaybeUTF8 qw(decode_json_utf8 encode_json_utf8);
use Log::Any        qw($log);
use LWP::UserAgent;
use Syntax::Keyword::Try;
use URI;
use URI::QueryParam;

use BOM::Config;
use BOM::Platform::Context qw(localize);

use constant {
    API_PATH               => '/api/v1/',
    DD_API_CALL_RESULT_KEY => 'bom_platform.cryptocashier.api.v_1.call.result'
};
use constant API_ENDPOINTS => {
    DEPOSIT            => 'deposit',
    TRANSACTIONS       => 'transactions',
    WITHDRAW           => 'withdraw',
    WITHDRAW_CANCEL    => 'withdraw_cancel',
    CRYPTO_CONFIG      => 'crypto_config',
    CRYPTO_ESTIMATIONS => 'crypto_estimations',
};

use constant HTTP_METHODS => {
    GET  => 'get',
    POST => 'post',
};

=head2 new

The constructor, returns a new instance of this module.

=cut

sub new {
    my ($class, $params) = @_;
    return bless {context_params => $params}, $class;
}

=head2 ua

Return a L<LWP::UserAgent> if already not declared otherwise return the same instance.

=cut

sub ua {
    my ($self) = @_;

    return $self->{ua} //= do {
        LWP::UserAgent->new(timeout => 20);
    };
}

=head2 config

Returns API configuration.

=cut

sub config {
    my $self = shift;
    return $self->{config} //= BOM::Config::crypto_api();
}

=head2 create_url

Generates the URL based on the passed arguments.

=over 4

=item * C<$endpoint> - api endpoint name (string)

=item * C<$args> - an hashref containing parameters to be added to the url

=back

=cut

sub create_url {
    my ($self, $endpoint, $args) = @_;

    my $api_url = $self->config->{host} . ':' . $self->config->{port};

    my $url = URI->new($api_url . API_PATH . $endpoint);
    $url->query_param_append($_, $args->{$_}) for sort keys $args->%*;

    my %context_params = %{$self->{context_params}}{qw/domain l language app_id source brand/};

    # In case the `app_id` and `l` (language) are missing in params, we set the
    # same from `source` and `language` for creating the correct request context
    $context_params{l}      //= $context_params{language};
    $context_params{app_id} //= $context_params{source};

    $url->query_param_append($_, $context_params{$_}) for sort keys %context_params;

    return $url->as_string;
}

=head2 deposit

Get a client crypto deposit address - in C<NEW> state.

Takes the following parameter:

=over 4

=item * C<$loginid>       - The client loginid

=item * C<$currency_code> - The currency_code

=back

Returns a hashref containing the deposit address or error.

=cut

sub deposit {
    my ($self, $loginid, $currency_code) = @_;

    my $result = $self->_request({
            method       => HTTP_METHODS->{GET},
            endpoint     => API_ENDPOINTS->{DEPOSIT},
            query_params => {
                loginid       => $loginid,
                currency_code => $currency_code,
            }});

    return $result if $result->{error};

    return {
        action  => 'deposit',
        deposit => {
            address => $result->{deposit_address},
        },
    };
}

=head2 withdraw

Withdraws the specified amount to the target address.

Takes the following parameters:

=over 4

=item * C<$loginid>       - The client loginid

=item * C<$address>       - Destination address to withdraw to

=item * C<$amount>        - Withdrawal amount

=item * C<$is_dry_run>    - If true, just do the validations

=item * C<$currency_code> - The currency_code

=back

Returns error if any validation failed.
On success, returns either the result of the validations (if C<$is_dry_run> was true):

=over 4

=item * C<dry_run> - C<1> validations succeeded

=back

Or the result of withdrawal operation containing the following keys:

=over 4

=item * C<id> - Transaction ID

=item * C<status_code> - Status of the transaction. e.g. C<LOCKED>

=item * C<status_message> - The status message based on the C<status_code>

=back

=cut

sub withdraw {
    my ($self, $loginid, $address, $amount, $is_dry_run, $currency_code, $client_locked_min_withdrawal_amount) = @_;

    my $result = $self->_request({
            method   => HTTP_METHODS->{POST},
            endpoint => API_ENDPOINTS->{WITHDRAW},
            payload  => {
                loginid                             => $loginid,
                address                             => $address,
                amount                              => $amount,
                dry_run                             => $is_dry_run,
                currency_code                       => $currency_code,
                client_locked_min_withdrawal_amount => $client_locked_min_withdrawal_amount,
            }});

    return $result if $result->{error};

    return {
        action   => 'withdraw',
        withdraw => $result,
    };
}

=head2 withdrawal_cancel

Cancels a withdrawal request which has not been verified yet. i.e. C<LOCKED>

Receives the following parameters:

=over 4

=item * C<$loginid>       - The client loginid

=item * C<$id>            - The ID of the withdrawal transaction to be cancelled

=item * C<$currency_code> - The currency_code

=back

Returns the result of the cancellation request containing the following keys:

=over 4

=item * C<id> - Transaction ID

=item * C<status_code> - Status of the transaction. e.g. C<CANCELLED>

=back

=cut

sub withdrawal_cancel {
    my ($self, $loginid, $id, $currency_code) = @_;

    unless ($id) {
        return create_error({
            code              => 'CryptoMissingRequiredParameter',
            message_to_client => localize('Missing or invalid required parameter.'),
            details           => {field => 'id'},
        });
    }

    my $result = $self->_request({
            method   => HTTP_METHODS->{POST},
            endpoint => API_ENDPOINTS->{WITHDRAW_CANCEL},
            payload  => {
                loginid       => $loginid,
                id            => $id,
                currency_code => $currency_code,
            }});

    return $result if $result->{error};

    return {
        id          => $result->{id},
        status_code => $result->{status_code},
    };
}

=head2 transactions

Retrieves a list of pending transactions.

Receives the following parameters:

=over 4

=item * C<$loginid>          - The client loginid

=item * C<$transaction_type> - Type of the transactions to return. C<deposit>, C<withdrawal>, or C<all> (default)

=item * C<$currency_code>    - The currency_code

=back

Returns pending transactions as an arrayref containing hashrefs with the following keys:

=over 4

=item * C<id> - Transaction ID

=item * C<address_hash> - The destination crypto address

=item * C<address_url> - The URL of the address on blockchain

=item * C<amount> - [Optional] The transaction amount. Not present when deposit transaction still unconfirmed.

=item * C<is_valid_to_cancel> - [Optional] Boolean value: 1 or 0, indicating whether the transaction can be cancelled. Only applicable for C<withdrawal> transactions

=item * C<status_code> - The status code of the transaction. Possible values for deposit: C<PENDING>, possible values for withdrawal: C<LOCKED>, C<VERIFIED>, C<PROCESSING>

=item * C<status_message> - The status message of the transaction

=item * C<submit_date> - The epoch of the transaction date

=item * C<transaction_hash> - [Optional] The transaction hash

=item * C<transaction_type> - The type of the transaction. C<deposit> or C<withdrawal>

=item * C<transaction_url> - [Optional] The URL of the transaction on blockchain

=back

=cut

sub transactions {
    my ($self, $loginid, $transaction_type, $currency_code) = @_;

    my $result = $self->_request({
            method       => HTTP_METHODS->{GET},
            endpoint     => API_ENDPOINTS->{TRANSACTIONS},
            query_params => {
                loginid          => $loginid,
                transaction_type => $transaction_type,
                currency_code    => $currency_code,
            }});

    return $result;
}

=head2 crypto_config

Retrieves crypto config for all the available currencies. If a currency code is passed then only retrieve config for passed currency code.

Receives the following parameters:

=over 4

=item * C<currency_code> - string (optional) Currency code to retrieve the config of

=back

Returns hashrefs with the following keys:

=over 4

=item * C<crypto_config> -hashref , contains the key valus as per https://api.deriv.com/api-explorer/#crypto_config

=back

=cut

sub crypto_config {
    my ($self, $currency_code) = @_;

    my $result = $self->_request({
        method       => HTTP_METHODS->{GET},
        endpoint     => API_ENDPOINTS->{CRYPTO_CONFIG},
        query_params => {($currency_code ? (currency_code => $currency_code) : ())},
    });

    return $result;
}

=head2 crypto_estimations

Retrieves crypto estimations for the currency code passed.

Receives the following parameters:

=over 4

=item * C<currency_code> - Currency code for which we want to get the estimations

=back

Returns hashrefs with the following keys:

=over 4

=item * C<crypto_estimations> -hashref , contains the key values as per https://api.deriv.com/api-explorer/#crypto_estimations

=back

=cut

sub crypto_estimations {
    my ($self, $currency_code) = @_;

    my $result = $self->_request({
            method       => HTTP_METHODS->{GET},
            endpoint     => API_ENDPOINTS->{CRYPTO_ESTIMATIONS},
            query_params => {currency_code => $currency_code}});

    return $result;

}

=head2 _request

Makes an HTTP request and returns the result.

Takes an hashref with following parameters as input:

=over 4

=item * C<method> - The request method, either C<GET> or C<POST>

=item * C<endpoint> - The request endpoint name. Ex: deposit/withdraw

=item * C<query_params> - HTTP GET request parameters to be added to the url

=item * C<payload> - HTTP POST request contents to be added to the request body, should be either a hashref or an encoded JSON

=back

Returns a hashref containing the response or error.

=cut

sub _request {
    my ($self, $params) = @_;

    my ($method, $endpoint, $query_params, $payload) = @{$params}{qw(method endpoint query_params payload)};

    my $uri = $self->create_url($endpoint, $query_params);

    my $result           = $self->ua->$method($uri, $payload // ());
    my $status           = $result->is_success ? "success" : "fail";
    my $currency_code    = $query_params->{currency_code} // $payload->{currency_code} // '';
    my $response_content = $result->{_content} // '';

    DataDog::DogStatsd::Helper::stats_inc(DD_API_CALL_RESULT_KEY, {tags => ["status:$status", "endpoint:$endpoint", "currency_code:$currency_code"]});

    unless ($result->is_success) {
        $log->warnf("Crypto API call faced network issue while requesting method: %s uri: %s error: %s", $method, $uri, $response_content);

        return create_error({
            code              => 'CryptoConnectionError',
            message_to_client => localize('An error occurred while processing your request. Please try again later.'),
            message           => $response_content,
        });
    }

    my $response = decode_json_utf8($response_content);
    if ($response->{error}) {
        $response->{error}{message_to_client} = delete $response->{error}{message};
    }
    return $response;
}

=head2 create_error

Description: Creates an error data structure that allows front-end to display the correct information

example

            return create_error({
                    code              => 'ASK_FIX_DETAILS',
                    message           => 'There was a failure validatin gperson details'
                    message_to_client => localize('There was a problem validating your personal details.'),
                    details           => {fields => \@error_fields}});

Takes the following arguments as named parameters

=over 4

=item - code:  A short string acting as a key for this error.

=item - message_to_client: A string that will be shown to the end user.
This will nearly always need to be translated using the C<localize()> method.

=item - message: (optional)  Message to be written to the logs. Only log messages that can be
acted on.

=item - details: (optional) An arrayref with meta data for the error.  Has the following
optional attribute(s)

=over 4

=item - fields:  an arrayref of fields affected by this error. This allows frontend
to display appropriate warnings.

=back

=back

Returns a hashref

        {
        error => {
            code              => "Error Code",
            message_to_client => "Message to client",
            message, => "message that will be logged",
            details => HashRef of metadata to send to frontend
        }

=cut

sub create_error {
    my $args = shift;

    return {
        error => {
            code              => $args->{code},
            message_to_client => $args->{message_to_client},
            $args->{message} ? (message => $args->{message}) : (),
            $args->{details} ? (details => $args->{details}) : ()}};
}

1;
