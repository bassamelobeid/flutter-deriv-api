package BOM::WebSocketAPI::v3::Wrapper::Cashier;

use strict;
use warnings;

use BOM::WebSocketAPI::Websocket_v3;

sub get_limits {
    return __call_rpc(shift, 'get_limits', @_);
}

sub paymentagent_list {
    return __call_rpc(shift, 'paymentagent_list', @_);
}

sub paymentagent_withdraw {
    my ($c, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'paymentagent_withdraw',
        sub {
            my $response = shift;
            if (exists $response->{error}) {
                $c->app->log->info($response->{error}->{message}) if (exists $response->{error}->{message});
                return $c->new_error('paymentagent_withdraw', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type              => 'paymentagent_withdraw',
                    paymentagent_withdraw => delete $response->{status},
                    %$response
                };
            }
        },
        {
            args        => $args,
            token       => $c->stash('token'),
            server_name => $c->server_name
        });
    return;
}

sub paymentagent_transfer {
    my ($c, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'paymentagent_transfer',
        sub {
            my $response = shift;
            if (exists $response->{error}) {
                $c->app->log->info($response->{error}->{message}) if (exists $response->{error}->{message});
                return $c->new_error('paymentagent_transfer', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type              => 'paymentagent_transfer',
                    paymentagent_transfer => delete $response->{status},
                    %$response
                };
            }
        },
        {
            args        => $args,
            token       => $c->stash('token'),
            server_name => $c->server_name,
        });
    return;
}

sub transfer_between_accounts {
    my ($c, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'transfer_between_accounts',
        sub {
            my $response = shift;
            if (exists $response->{error}) {
                $c->app->log->info($response->{error}->{message}) if (exists $response->{error}->{message});
                return $c->new_error('transfer_between_accounts', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type                  => 'transfer_between_accounts',
                    transfer_between_accounts => delete $response->{status},
                    %$response
                };
            }
        },
        {
            args  => $args,
            token => $c->stash('token'),
        });
    return;
}

sub topup_virtual {
    return __call_rpc(shift, 'topup_virtual', @_);
}

sub cforward {
    return __call_rpc(shift, 'cashier', @_);
}

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
            args     => $args,
            token    => $c->stash('token'),
            language => $c->stash('language')});
}

1;
