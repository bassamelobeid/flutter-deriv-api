package BOM::RPC::v3::Services::PandaTS;

=head1 NAME

BOM::RPC::v3::Services::PandaTS - helpers for PandaTS service

=head1 DESCRIPTION

This module contains the helpers for dealing with PandaTS service.

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
    return $self->{config} //= BOM::Config::third_party()->{pandats};
}

=head2 generate_token

Communicate with third-party API to generate token based on MT user data

Returns a Future containing token

=cut

sub generate_token {
    my ($self) = @_;

    my $email   = $self->client->email;
    my $loginid = $self->client->loginid;

    return $self->http_client->GET(
        $self->create_login_url(
            email  => $email,
            login  => '20000005',    # MT username - hardcoded for testing purposes (only available user)
            source => 2,             # server
        ),
        user => $self->config->{username},
        pass => $self->config->{password}
    )->then(
        sub {
            my $response = shift;

            my $json;
            try {
                $json = decode_json_utf8 $response->content;
            } catch ($e) {
                $log->errorf('An error occurred during parsing PandaTS response json, %s', $e);
            };

            die $response unless $json and $json->{token};

            return Future->done({token => $json->{token}});
        }
    )->else(
        sub {
            my ($response) = grep { (ref $_ // '') =~ /HTTP::Response/ } @_;

            if ($response) {
                $self->handle_api_error($response);
            } else {
                $log->errorf('An unexpected error occurred while creating login token for PandaTS service due to %s', $response);
            }

            return Future->done({
                    error => BOM::RPC::v3::Utility::create_error({
                            code              => 'PandaTSTokenGenerationError',
                            message_to_client => localize('Cannot generate token for [_1].', $loginid),
                        })});
        });
}

=head2 create_login_url

Generates the URL based on the passed arguments.

=cut

sub create_login_url {
    my ($self, %queryparams) = @_;

    my $api_url = sprintf '%s/login', $self->config->{base_url};

    my $u = URI->new($api_url);
    $u->query_param_append($_, $queryparams{$_}) for keys %queryparams;

    return $u->as_string;
}

=head2 handle_api_error

Handles API error response and log error for further investigations

=cut

sub handle_api_error {
    my ($self, $response) = @_;

    my $json = eval { decode_json_utf8($response->content) };

    $log->errorf('Cannot create login token for PandaTS, reqId: %s, api message: %s, http status code: %s',
        $json->{reqId}, $json->{msg}, $response->code)
        if $json;

    return undef;
}

1;
