package BOM::Platform::CryptoCashier::InternalAPI;

=head1 NAME

BOM::Platform::CryptoCashier::InternalAPI

=head1 DESCRIPTION

This module contains the helpers for calling our crypto cashier services for the internal services and scripts.

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

use constant {
    API_PATH               => '/api/v1/',
    DD_API_CALL_RESULT_KEY => 'bom_platform.cryptocashier.internal_api.v_1.call.result'
};

use constant API_ENDPOINTS => {
    PROCESS_BATCH => 'process_batch',
};

use constant HTTP_METHODS => {
    GET  => 'GET',
    POST => 'POST',
};

=head2 new

The constructor, returns a new instance of this module.

=cut

sub new {
    my ($class, %args) = @_;
    return bless {context_params => \%args}, $class;
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

Gets crypto cashier internal api configuration.

=cut

sub config {
    my $self = shift;
    return $self->{config} //= BOM::Config::crypto_internal_api();
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

    return $url->as_string;
}

=head2 process_batch

Process batch of requests.

Takes a hashref containing the following named parameter:

=over 4

=item * C<requests>   - arrayref (required) containing one or more requests of the batch. Each request having the following named parameters:

=over 4

=item * C<id>         - string   (required) Unique identifier of the current request

=item * C<action>     - string   (required) The action of request, in the format of C<category/method>

=item * C<body>       - hashref  (optional) The request payload

=item * C<depends_on> - arrayref (optional) List of C<id> values in the same batch that execution of this request depends on success execution of them all

=back

=back

Returns a hashref containing standard error structure if the whole batch was rejected due to validation error:
Otherwise, a hashref for the final response containing the following named parameter:

=over 4

=item * C<responses> - An arrayref containing responses corresponding requests of the batch. Each response having the following named parameters:

=over 4

=item * C<id>     - string   Unique identifier of the current request

=item * C<status> - boolean  C<1> if the corresponding request processed (no matter succeeded or failed with an error), and C<0> if not processed due to an issue (like invalid request)

=item * C<body>   - hashref  Hashref containing the response or error

=back

=back

=cut

sub process_batch {
    my ($self, $requests) = @_;

    return $self->_request({
            method   => HTTP_METHODS->{POST},
            endpoint => API_ENDPOINTS->{PROCESS_BATCH},
            payload  => {
                requests => $requests,
            }});
}

=head2 _request

Makes an HTTP request and returns the result.

Takes an hashref with following parameters as input:

=over 4

=item * C<method>       - The request method, either C<GET> or C<POST>

=item * C<endpoint>     - The request endpoint name. Ex: deposit/withdraw

=item * C<query_params> - HTTP GET request parameters to be added to the url

=item * C<payload>      - HTTP POST request contents to be added to the request body, should be either a hashref or an encoded JSON

=back

Returns a hashref containing the response or error.

=cut

sub _request {
    my ($self, $params) = @_;

    my ($method, $endpoint, $query_params, $payload) = @{$params}{qw(method endpoint query_params payload)};

    my $uri = $self->create_url($endpoint, $query_params);

    my $req = HTTP::Request->new($method, $uri);
    $req->header('Content-Type' => 'application/json');

    if ($payload) {
        my $json = encode_json_utf8($payload);
        $req->content($json);
    }

    my $result           = $self->ua->request($req);
    my $status           = $result->is_success ? "success" : "fail";
    my $response_content = $result->{_content} // '';

    DataDog::DogStatsd::Helper::stats_inc(DD_API_CALL_RESULT_KEY, {tags => ["status:$status", "endpoint:$endpoint"]});

    unless ($result->is_success) {
        $log->warnf("Crypto API call faced network issue while requesting method: %s uri: %s error: %s", $method, $uri, $response_content);

        return create_error({
            code              => 'CryptoConnectionError',
            message_to_client => 'An error occurred while processing your request. Please try again later.',
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
                    message_to_client => 'There was a problem validating your personal details.',
                    details           => {fields => \@error_fields}});

Takes the following arguments as named parameters

=over 4

=item - code:  A short string acting as a key for this error.

=item - message_to_client: A string that will be shown to the end user.

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
