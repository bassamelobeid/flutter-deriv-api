package BOM::RPC::v3::Services::Crypto;

=head1 NAME

BOM::RPC::v3::Services::Crypto

=head1 DESCRIPTION

This module contains the helpers for calling our crypto services.

=cut

use strict;
use warnings;

use JSON::MaybeUTF8 qw(decode_json_utf8 encode_json_utf8);
use Syntax::Keyword::Try;
use URI;
use URI::QueryParam;

use BOM::Config;
use BOM::Platform::Context qw(localize);
use BOM::RPC::v3::Utility;

use constant API_PATH      => '/api/v1/';
use constant API_ENDPOINTS => {
    DEPOSIT         => 'deposit',
    TRANSACTIONS    => 'transactions',
    WITHDRAW        => 'withdraw',
    WITHDRAW_CANCEL => 'withdraw_cancel',
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

Gets api configuration.

=cut

sub config {
    my $self = shift;
    return $self->{config} //= BOM::Config::crypto_api();
}

=head2 create_url

Generates the URL based on the passed arguments.

=cut

sub create_url {
    my ($self, $api_name, $args) = @_;

    my $api_url = $self->config->{host} . ':' . $self->config->{port};

    my $url = URI->new($api_url . API_PATH . API_ENDPOINTS->{$api_name});
    $url->query_param_append($_, $args->{$_}) for sort keys $args->%*;

    my %context_params = %{$self->{context_params}}{qw/domain language source brand/};
    $url->query_param_append($_, $context_params{$_}) for sort keys %context_params;

    return $url->as_string;
}

=head2 deposit

Get a client crypto deposit address - in C<NEW> state.

Takes the following parameter:

=over 4

=item * C<$loginid> - The client loginid

=back

Returns a hashref containing the deposit address or error.

=cut

sub deposit {
    my ($self, $loginid) = @_;

    my $url    = $self->create_url(DEPOSIT => {loginid => $loginid});
    my $result = $self->_request(GET => $url);

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

=item * C<$loginid> - The client loginid

=item * C<$address> - Destination address to withdraw to

=item * C<$amount> - Withdrawal amount

=item * C<$is_dry_run> - If true, just do the validations

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
    my ($self, $loginid, $address, $amount, $is_dry_run) = @_;

    unless ($address && $amount) {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'CryptoMissingRequiredParameter',
            message_to_client => localize('Missing or invalid required parameter.'),
            details           => {field => !$address ? 'address' : 'amount'},
        });
    }

    my $url    = $self->create_url('WITHDRAW');
    my $result = $self->_request(
        POST => $url => {
            loginid => $loginid,
            address => $address,
            amount  => $amount,
            dry_run => $is_dry_run,
        });

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

=item * C<$loginid> - The client loginid

=item * C<$id> - The ID of the withdrawal transaction to be cancelled

=back

Returns the result of the cancellation request containing the following keys:

=over 4

=item * C<id> - Transaction ID

=item * C<status_code> - Status of the transaction. e.g. C<CANCELLED>

=back

=cut

sub withdrawal_cancel {
    my ($self, $loginid, $id) = @_;

    unless ($id) {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'CryptoMissingRequiredParameter',
            message_to_client => localize('Missing or invalid required parameter.'),
            details           => {field => 'id'},
        });
    }

    my $url    = $self->create_url('WITHDRAW_CANCEL');
    my $result = $self->_request(
        POST => $url => {
            loginid => $loginid,
            id      => $id,
        });

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

=item * C<$loginid> - The client loginid

=item * C<$transaction_type> - Type of the transactions to return. C<deposit>, C<withdrawal>, or C<all> (default)

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
    my ($self, $loginid, $transaction_type) = @_;

    my $url = $self->create_url(
        TRANSACTIONS => {
            loginid          => $loginid,
            transaction_type => $transaction_type,
        });
    my $result = $self->_request(GET => $url);

    return $result if ref $result eq 'HASH' and $result->{error};

    return $result;
}

=head2 _request

Makes an HTTP request.

Takes the following parameters:

=over 4

=item * C<$method> - The request method, either C<GET> or C<POST>

=item * C<$uri> - The endpoint URI

=item * C<$content> - The request contents, should be either a hashref or an encoded JSON

=back

Returns a hashref containing the response or error.

=cut

sub _request {
    my ($self, $method, $uri, $content) = @_;

    $method = lc $method;
    my $result = $self->ua->$method($uri, $content // ());

    unless ($result->is_success) {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'CryptoConnectionError',
            message_to_client => localize('An error occurred while processing your request. Please try again later.'),
            message           => $result->{_content},
        });
    }

    my $response = decode_json_utf8($result->{_content});
    if ($response->{error}) {
        $response->{error}{message_to_client} = delete $response->{error}{message};
    }
    return $response;
}

1;
