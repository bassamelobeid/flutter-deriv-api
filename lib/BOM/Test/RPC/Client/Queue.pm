package BOM::Test::RPC::Client::Queue;

use Job::Async::Client::Redis;
use JSON::MaybeUTF8 qw(encode_json_utf8 decode_json_utf8);
use MojoX::JSON::RPC::Client;

use BOM::Test::WebsocketAPI::Redis::RpcQueue;

use Moose;
use namespace::autoclean;

extends 'BOM::Test::RPC::Client';

=head1 NAME

BOM::Test::RPC::Client::Queue

=head1 DESCRIPTION

A class repsenting a test client for invoking method over rpc queue and analyze the results, in a similar way as the http rpc calls.
It is a subclass of C<BOM::Test::RPC::Client> with identical public API.

=head2

=cut

has '+ua' => (required => 0);

has '+client' => (
    is         => 'ro',
    isa        => 'Job::Async::Client::Redis',
    builder    => '_build_client',
    lazy_build => 1,
);

has 'loop' => (
    is       => 'ro',
    required => 1,
    builder  => '_build_loop',
);

sub _build_loop {
    return IO::Async::Loop::Mojo->new;
}

sub _build_client {
    my $self         = shift;
    my $queue_redis  = BOM::Test::WebsocketAPI::Redis::RpcQueue->new->config->{write};
    my $queue_prefix = $ENV{JOB_QUEUE_PREFIX};
    $self->loop->add(
        my $client = Job::Async::Client::Redis->new(
            uri     => 'redis://' . $queue_redis->{host} . ':' . $queue_redis->{port},
            timeout => 5,
            $queue_prefix ? (prefix => $queue_prefix) : (),
        ));
    $client->start->get;
    return $client;
}

sub _tcall {
    my ($self, $method, $req_params) = @_;

    $self->params([$method, $req_params]);

    $req_params->{args}->{$method} //= 1;
    my $request = {
        name   => $method,
        params => encode_json_utf8($req_params),
    };
    my $result = Future->wait_any($self->client->submit(%$request), $self->loop->delay_future(after => 10))->get;

    my $r;
    $r = MojoX::JSON::RPC::Client::ReturnObject->new(rpc_response => decode_json_utf8($result)) if $result;

    $self->response($r);
    $self->result($r->result) if $r;
    return $r;
}

__PACKAGE__->meta->make_immutable;
1;
