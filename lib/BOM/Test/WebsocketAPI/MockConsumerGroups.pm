package BOM::Test::WebsocketAPI::MockConsumerGroups;

no indirect;

use warnings;
use strict;

=head1 NAME

BOM::Test::WebsocketAPI::MockConsumerGroups - Mock ConsumerGroups RPC response for websocket tests

=head1 SYNOPSIS

    use BOM::Test::WebsocketAPI::MockConsumerGroups;

=head1 DESCRIPTION

This module will mock `request` of C<Mojo::WebSocketProxy::Backend::ConsumerGroup> and
`new` of C<MojoX::JSON::RPC::Client> to reproduce expected results for subscription 
tests based on C<Mojo::WebSocketProxy::Backend::ConsumerGroup> proxy.

=cut

use MojoX::JSON::RPC::Client;
use JSON::MaybeUTF8 qw( decode_json_utf8 );

use Mojo::WebSocketProxy::Backend::ConsumerGroups;
use BOM::Test::WebsocketAPI::Data qw( rpc_response );

my $request_body;

{
    no warnings qw(redefine);    ## no critic (ProhibitNoWarnings)

    *Mojo::WebSocketProxy::Backend::ConsumerGroups::request = sub {
        $request_body          = {$_[1]->@*};
        $request_body->{args}  = decode_json_utf8($request_body->{args})  if $request_body->{args};
        $request_body->{stash} = decode_json_utf8($request_body->{stash}) if $request_body->{stash};

        $request_body->{params} = delete $request_body->{args};
        $request_body->{method} = delete $request_body->{rpc};

        return Future->done;
    };

    *MojoX::JSON::RPC::Client::ReturnObject::new = sub {
        return rpc_response($request_body);
    }
}

1;
