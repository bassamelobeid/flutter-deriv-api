package BOM::Platform::Script::DevExpertsAPIService;

use strict;
use warnings;

use parent qw(IO::Async::Notifier);

use Future::AsyncAwait;
use Syntax::Keyword::Try;
use Net::Async::HTTP::Server;
use IO::Async::Timer::Periodic;
use HTTP::Response;
use JSON::MaybeUTF8 qw(:v1);
use Unicode::UTF8;
use Scalar::Util               qw(refaddr blessed);
use DataDog::DogStatsd::Helper qw(stats_inc stats_timing);
use curry::weak;
use Time::HiRes qw(gettimeofday tv_interval);
use URI;

$Future::TIMES = 1;

use Log::Any qw($log);

=head1 NAME

DevExperts API Service

=head1 DESCRIPTION

Base class for services providing HTTP access to DevExperts API wrappers.

All requests are made by POST with json payload. Any path will work.
Payload must contain C<method> which is the name of the API wrapper method to call. E.g.

  curl -X POST localhost:8081 -d '{"method":"account_create", "clearing_code":"myclearing"}'

=cut

=head2 configure

Apply configuration from new().

Takes the following named parameters:

=over 4

=item * C<listen_port> - port for incoming requests. A random free port will be assigned if empty.

=item * Cdemo_host> - devexperts demo server host name including protocol.

=item * Cdemo_port> - demo server port.

=item * Cdemo_user> - demo server username

=item * Cdemo_pass> - demo server password

=item * Creal_host> - devexperts real server host name including protocol.

=item * Creal_port> - real server port

=item * Creal_user> - real server username

=item * Creal_pass> - real server password

=back

=cut

sub configure {
    my ($self, %args) = @_;

    for (qw(listen_port demo_host demo_port demo_user demo_pass real_host real_port real_user real_pass close_after_request connections timeout)) {
        $self->{$_} = delete $args{$_} if exists $args{$_};
    }

    $self->{demo_host_base}                 = URI->new($self->{demo_host})->host;
    $self->{real_host_base}                 = URI->new($self->{real_host})->host;
    $self->@{qw/demo_username demo_domain/} = split '@', ($self->{demo_user} // '');
    $self->@{qw/real_username real_domain/} = split '@', ($self->{real_user} // '');

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

    my ($server, $method);

    try {
        die "Only POST is allowed\n" unless $req->method eq 'POST';
        my $params = decode_json_utf8($req->body || '{}');
        $server = $params->{server}        || '<none>';
        $method = delete $params->{method} || '<none>';
        die "Invalid server: $server\n" unless exists $self->{clients}{$server};
        die "Invalid method: $method\n" unless $self->{clients}{$server}->can($method);
        $log->debugf('Got request for method %s with params %s', $method, $params);

        my ($data, $timing) = await $self->call_api($server, $method, $params);

        my $response = HTTP::Response->new(200);
        $response->header(timing => $timing);
        my $response_content;

        if (ref $data) {
            if (ref $data eq 'ARRAY') {
                $response_content = [map { $_->as_fields } $data->@*];
            } elsif (blessed($data) and $data->isa('WebService::Async::DevExperts::BaseModel')) {
                $response_content = $data->as_fields;
            }
            $response->add_content(encode_json_utf8($response_content));
            $response->content_type("application/javascript");
        }

        if ($data and not $response->content) {
            $response->add_content($data);
            $response->content_type("text/plain");
        }

        $response->content_length(length $response->content);
        $req->respond($response);
    } catch ($e) {
        chomp($e);
        $log->debugf('Failed processing request: %s', $e);

        try {
            if (blessed($e) and $e->isa('WebService::Async::DevExperts::BaseModel')) {
                my $response      = HTTP::Response->new($e->http_code);
                my $response_data = $e->as_fields;

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
                stats_inc($self->{datadog_prefix} . 'unexpected_error', {tags => ['server:' . ($server // ''), 'method:' . ($method // '')]});
            }
        } catch ($e2) {
            $log->errorf('Failed when trying to send failure response - %s', $e2);
        }
    }
}

=head2 call_api

Perform API request.

=cut

async sub call_api {
    my ($self, $server, $method, $params) = @_;

    stats_inc($self->{datadog_prefix} . 'request', {tags => ["server:$server", "method:$method"]});
    $log->tracef('Calling %s server, method %s with params %s', $server, $method, $params);

    my $start_time = [Time::HiRes::gettimeofday];
    my $resp       = await $self->{clients}{$server}->$method($params->%*);
    my $timing     = 1000 * Time::HiRes::tv_interval($start_time);

    stats_timing($self->{datadog_prefix} . 'timing', $timing, {tags => ["server:$server", "method:$method"]},);

    return $resp, $timing;
}

=head2 start

Starts the http server listening.
Resolves to the actual port that is being listened to.

=cut

async sub start {
    my ($self) = @_;

    $log->tracef('Starting API service for %s on port %s', ref($self), $self->{listen_port} // '<undefined>');

    my $listner = await $self->{server}->listen(
        addr => {
            family   => 'inet',
            socktype => 'stream',
            port     => $self->{listen_port}});
    my $port = $listner->read_handle->sockport;

    $log->tracef('API service for %s is listening on port %s', ref($self), $port);
    return $port;
}

1;
