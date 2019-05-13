package BOM::Test::WebsocketAPI::MockRPC;

no indirect;
use warnings;
use strict;

=head1 NAME

BOM::Test::WebsocketAPI::MockRPC - Mock RPC calls for websocket testing

=head1 SYNOPSIS

    use BOM::Test::WebsocketAPI::MockRPC;

=head1 DESCRIPTION

By default this module will mock all RPC calls which are known to be used for
subscription, those calls are stored in the C<BOM::Test::WebsocketAPI::Data>.

=cut

use BOM::Test::WebsocketAPI::Data qw( rpc_response );
use MojoX::JSON::RPC::Client;

my $original_call = \&MojoX::JSON::RPC::Client::call;

{
    no warnings qw(redefine);    ## no critic (ProhibitNoWarnings)

    *MojoX::JSON::RPC::Client::call = sub {
        my ($self, $uri, $body, $callback) = @_;
        # Fall back to original RPC call if there is no mock data available
        return $original_call->(@_) unless my $rpc_response = rpc_response($body);
        $callback->($rpc_response);
    };
};

1;
