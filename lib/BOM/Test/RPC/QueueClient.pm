package BOM::Test::RPC::QueueClient;

use Test::MockObject;

use BOM::RPC::Transport::Redis;

use Moose;
use namespace::autoclean;

extends 'BOM::Test::RPC::Client';

=head1 NAME

BOM::Test::RPC::QueueClient

=head1 DESCRIPTION

An RPC client for invoking methods over RPC Redis and analyzing the results.
It is a subclass of L<BOM::Test::RPC::Client>, compatibly borrowing all the internal mechanisms.

=head2

=cut

has '+ua' => (required => 0);

has '+client' => (
    is         => 'ro',
    isa        => 'BOM::RPC::Transport::Redis',
    builder    => '_build_client',
    lazy_build => 1,
);

sub _build_client {
    my $self = shift;

    my $client = BOM::RPC::Transport::Redis->new(
        redis_uri    => Test::MockObject->new(),
        worker_index => 0,
    );

    return $client;
}

sub _tcall {
    my ($self, $method, $req_params) = @_;

    $self->params([$method, $req_params]);

    my $request = {
        rpc  => $method,
        args => $req_params,
    };

    my $result = $self->client->_dispatch_request($request);

    my $r = MojoX::JSON::RPC::Client::ReturnObject->new(rpc_response => {result => $result});

    $self->response($r);
    $self->result($r->result) if $r;

    return $r;
}

__PACKAGE__->meta->make_immutable;

1;
