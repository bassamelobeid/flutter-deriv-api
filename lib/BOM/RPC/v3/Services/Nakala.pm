package BOM::RPC::v3::Services::Nakala;

=head1 NAME

BOM::RPC::v3::Services::Nakala - helpers for B2Broker(Nakala) service

=head1 DESCRIPTION

This module contains the helpers for dealing with Nakala service.

=cut

use strict;
use warnings;

use utf8;

no indirect;

use JSON::MaybeUTF8 qw( :v1 );
use IO::Async::Loop;
use Log::Any qw( $log );
use Net::Async::HTTP;
use Syntax::Keyword::Try;

use BOM::Config;
use BOM::Platform::Context qw( localize );
use BOM::RPC::v3::Services;
use BOM::RPC::v3::Utility;

=head2 new

Initiate the service

=cut

sub new {
    my ($class, %params) = @_;

    die 'Client is required.' unless $params{client};

    return bless \%params, $class;
}

=head2 client

A getter for L<BOM::User::Client> object

=cut

sub client { shift->{client} }

=head2 loop

Returns IO::Async::Loop instance.

=cut

sub loop {
    my $self = shift;
    return $self->{loop} //= IO::Async::Loop->new();
}

=head2 http_client

Returns Net::Async::HTTP instance.

=cut

sub http_client {
    my $self = shift;
    return $self->{http_client} //= do {
        $self->loop->add(
            my $http_client = Net::Async::HTTP->new(
                fail_on_error => 1,
            ));
        $http_client;
    };
}

=head2 config

Gets API configuration.

=cut

sub config {
    my $self = shift;
    return $self->{config} //= BOM::Config::third_party()->{nakala};
}

=head2 nakala_id

Get the Nakala login id for client

=cut

sub nakala_id { 532245 }    # hardcoding loginid for now as we don't have nakala id implementation yet.

=head2 generate_token

Communicate with third-party API to generate token based on MT user data

Returns a Future containing token

=cut

sub generate_token {
    my ($self) = @_;

    $HTTP::Headers::TRANSLATE_UNDERSCORE = 0;    #bypass underscoer

    my $req;
    try {
        $req = $self->create_auth_request;
        $self->http_client->configure(+headers => $req->{headers});
    } catch ($e) {
        $log->errorf('An error occurred during creating request for Nakala, %s', $e);
        return $self->create_error;
    }

    return $self->http_client->POST($req->{url}, $req->{payload}, content_type => 'application/json')->then(
        sub {
            my $response = shift;

            $HTTP::Headers::TRANSLATE_UNDERSCORE = 1;    #rest

            my $json;
            try {
                $json = decode_json_utf8 $response->content;
            } catch ($e) {
                $log->errorf('An error occurred during parsing Nakala response json, %s', $e);
            };
            die $response unless $json;

            #nakala returns success code always even if error.
            if ($self->handle_api_error($response)) {
                return $self->create_error;
            }

            return Future->done({token => $json->{result}->{AccessToken}});
        }
    )->else(
        sub {
            my $error = shift;

            $HTTP::Headers::TRANSLATE_UNDERSCORE = 1;    #rest

            $log->errorf('An unexpected error occurred while creating login token for Nakala service due to %s', $error);

            return $self->create_error;
        });
}

=head2 create_auth_request

Generates the request's info URL, headers nad payload.

=cut

sub create_auth_request {
    my ($self) = @_;

    my $api_url = sprintf '%s/dx', $self->config->{base_url};

    my $headers = {
        "la_type"     => 0,
        "la_login"    => $self->nakala_id,
        "ManagerName" => $self->config->{mgr_name},
        "ManagerPass" => $self->config->{mgr_pass}};

    my $payload = {
        jsonrpc => "2.0",
        id      => undef,
        method  => "la.auth",
        params  => {"wa_login" => $self->nakala_id}};
    my $payload_json = encode_json_text($payload);
    my $u            = URI->new($api_url);

    return {
        url     => $u->as_string,
        headers => $headers,
        payload => $payload_json,
    };
}

=head2 create_error

create a general error future object with code and message

=cut

sub create_error {
    my $self = shift;

    return Future->done({
            error => BOM::RPC::v3::Utility::create_error({
                    code              => 'NakalaTokenGenerationError',
                    message_to_client => localize('Cannot generate token for [_1].', $self->nakala_id),
                })});
}

=head2 handle_api_error

Handles API error response and log error for further investigations.
returns 1 if the response is error response, undef otherwiese.

=cut

sub handle_api_error {
    my ($self, $response) = @_;

    my $json = eval { decode_json_utf8($response->content) };

    unless ($json) {
        $log->errorf('Unknown response received from api while requesting Nakala login token: %s', $response->content);
        return 1;
    }

    if ($json->{error}) {
        $log->errorf(
            'Cannot create login token for Nakala, api code: %s, api message: %s, http status code: %s',
            $json->{error}->{code},
            $json->{error}->{message},
            $response->code
        );
        return 1;
    }

    unless ($json->{result}->{user}) {
        $log->errorf('Cannot create login token for Nakala - Acocunt not found for: %s.', $self->nakala_id);
        return 1;
    }

    return undef;
}

1;
