package BOM::WebSocketAPI::v3::Wrapper::Offerings;

use strict;
use warnings;

use BOM::WebSocketAPI::Websocket_v3;

sub contracts_for {
    my ($c, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'contracts_for',
        sub {
            my $response = shift;
            if ($response->{error}) {
                return $c->new_error('contracts_for', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type      => 'contracts_for',
                    contracts_for => $response,
                };
            }
        },
        {args => $args});
    return;
}

1;
