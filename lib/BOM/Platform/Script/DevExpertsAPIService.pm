package BOM::Platform::Script::DevExpertsAPIService;

use strict;
use warnings;

use parent qw(IO::Async::Notifier);

use Future::AsyncAwait;
use Syntax::Keyword::Try;
use Net::Async::HTTP::Server;
use WebService::Async::DevExperts::Client;
use WebService::Async::DevExperts::Model::Common;
use HTTP::Response;
use JSON::MaybeUTF8 qw(:v1);
use Unicode::UTF8;
use Scalar::Util qw(refaddr blessed);

use Log::Any qw($log);

=head1 NAME

DevExperts API Service

=head1 DESCRIPTION

Provides an HTTP interface to DevExperts API wrapper.

All requests are made by POST with json payload. Any path will work.
Payload must contain C<method> which is the name of the API wrapper method to call. E.g.

  curl -X POST localhost:8081 -d '{"method":"account_create", "clearing_code":"myclearing"}'

=cut

=head2 configure

Apply configuration from new().

Takes the following named parameters:

=over 4

=item * C<listen_port> - port for incoming requests. A random free port will be assigned if empty.

=item * C<api_host> - DNS Name or IP address  of devexperts API server.

=item * C<api_port> - port of devexperts API server.

=item * C<api_auth> - 'hmac' or 'auth' authentication type. Default is hmac.

=item * C<api_key> - public API token of devexperts API server, used for hmac auth.

=item * C<api_secret> - private API token of devexperts API server, used for hmac auth.

=item * C<api_user> - username for basic authentication.

=item * C<api_pass> - password for basic authentication.

=back

=cut

sub configure {
    my ($self, %args) = @_;

    for (qw(listen_port api_host api_port api_auth api_key api_secret api_user api_pass)) {
        $self->{$_} = delete $args{$_} if exists $args{$_};
    }
    return $self->next::method(%args);
}

=head2 _add_to_loop

Called when we are added to loop. Creates http server and API client.

=cut

sub _add_to_loop {
    my ($self) = @_;

    # server for incoming requests
    $self->add_child(
        $self->{server} = Net::Async::HTTP::Server->new(
            on_request => sub {
                my ($http, $req) = @_;
                # without this we will have "lost its returning future" errors
                my $k = refaddr($req);
                $self->{active_requests}{$k} = $self->handle_http_request($req)->on_ready(sub { delete $self->{active_requests}{$k} });
            }));

    # devexperts API client
    $self->add_child(
        $self->{client} = WebService::Async::DevExperts::Client->new(
            host       => $self->{api_host},
            service    => $self->{api_port},
            auth       => $self->{api_auth},
            api_key    => $self->{api_key},
            api_secret => $self->{api_secret},
            user       => $self->{api_user},
            pass       => $self->{api_pass},
        ));

    return undef;
}

=head2 handle_http_request

Handles incoming requests, calls devexperts API, resolves to API response.

Takes the following parameter:

=over 4

=item  C<$req> :  L<Net::Async::HTTP::Server::Request> object.

=back

=cut

async sub handle_http_request {
    my ($self, $req) = @_;

    try {
        die "Only POST is allowed\n" unless $req->method eq 'POST';
        my $params = decode_json_utf8($req->body || '{}');
        my $method = delete $params->{method} || die "Method not provided\n";
        $log->debugf('Got request for method %s with params %s', $method, $params);
        my $data     = await $self->{client}->$method($params->%*);
        my $response = HTTP::Response->new(200);
        my $response_content;
        if ($data) {
            if (ref $data eq 'ARRAY') {
                $response_content = [map { WebService::Async::DevExperts::Model::Common::convert_case($_->as_hashref) } $data->@*];
            } else {
                $response_content = WebService::Async::DevExperts::Model::Common::convert_case($data->as_hashref);
            }
        }
        $response->add_content($response_content ? encode_json_utf8($response_content) : '');
        $response->content_length(length $response->content);
        $response->content_type("application/javascript");
        $req->respond($response);
    } catch ($e) {
        $log->debugf('Failed processing request: %s', $e);
        try {
            if (blessed($e) and $e->isa('WebService::Async::DevExperts::Model::Error')) {
                my $response      = HTTP::Response->new($e->http_code);
                my $response_data = WebService::Async::DevExperts::Model::Common::convert_case($e->as_hashref);
                $response->add_content(encode_json_utf8($response_data));
                $response->content_length(length $response->content);
                $response->content_type("application/javascript");
                $req->respond($response);
            } else {
                chomp($e);
                my $response = HTTP::Response->new(500);
                $response->content_type("text/plain");
                $response->add_content(ref $e ? encode_json_utf8($e) : Unicode::UTF8::encode_utf8("$e"));
                $response->content_length(length $response->content);
                $req->respond($response);
            }
        } catch ($e2) {
            $log->errorf('Failed when trying to send failure response - %s', $e2);
        }
    }
}

=head2 start

Starts the http server listening.
Resolves to the actual port that is being listened to.

=cut

async sub start {
    my ($self) = @_;

    my $listner = await $self->{server}->listen(
        addr => {
            family   => 'inet',
            socktype => 'stream',
            port     => $self->{listen_port}});
    my $port = $listner->read_handle->sockport;

    $log->tracef('DevExperts API service is listening on port %s', $port);
    return $port;
}

1;
