package BOM::WebSocketAPI::v3::Wrapper::Static;

use strict;
use warnings;

use BOM::RPC::v3::Static;

sub residence_list {
    my ($c, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'residence_list',
        sub {
            my $response = shift;
            return {
                msg_type       => 'residence_list',
                residence_list => $response,
            };
        },
        {args => $args});
    return;
}

sub states_list {
    my ($c, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'states_list',
        sub {
            my $response = shift;
            return {
                msg_type    => 'states_list',
                states_list => $response,
            };
        },
        {args => $args});
    return;
}

1;
