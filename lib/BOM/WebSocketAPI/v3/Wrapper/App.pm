package BOM::WebSocketAPI::v3::Wrapper::App;

use strict;
use warnings;
use BOM::WebSocketAPI::Websocket_v3;

sub __call_rpc {
    my ($c, $method, $args) = @_;

    return BOM::WebSocketAPI::Websocket_v3::rpc(
        $c, $method,
        sub {
            my $response = shift;
            if (ref($response) eq 'HASH' and exists $response->{error}) {
                return $c->new_error($method, $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type => $method,
                    $method  => $response,
                };
            }
        },
        {
            args           => $args,
            token          => $c->stash('token'),
            client_loginid => $c->stash('loginid'),
        });
}

sub register {
    return __call_rpc(shift, 'app_register', @_);
}

sub list {
    return __call_rpc(shift, 'app_list', @_);
}

sub get {
    return __call_rpc(shift, 'app_get', @_);
}

sub delete {    ## no critic (Subroutines::ProhibitBuiltinHomony
    return __call_rpc(shift, 'app_delete', @_);
}

1;
