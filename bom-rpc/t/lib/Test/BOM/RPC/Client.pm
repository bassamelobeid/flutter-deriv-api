package Test::BOM::RPC::Client;
use strict;
use warnings;
use Test::More;
use Data::Dumper;
use MojoX::JSON::RPC::Client;

@Test::BOM::RPC::Client::ISA = qw(MojoX::JSON::RPC::Client);

sub tcall {
    my $self   = shift;
    my $method = shift;
    my $params = shift;
    my $r      = $self->call_response($method, $params);
    ok($r->result,    'rpc response ok');
    ok(!$r->is_error, 'rpc response ok');
    if ($r->is_error) {
        diag(Dumper($r));
    }
    return $r->result;
}

sub call_response {
    my $self   = shift;
    my $method = shift;
    my $params = shift;
    my $r      = $self->call(
        "/$method",
        {
            id     => Data::UUID->new()->create_str(),
            method => $method,
            params => $params
        });
    return $r;
}

1;
