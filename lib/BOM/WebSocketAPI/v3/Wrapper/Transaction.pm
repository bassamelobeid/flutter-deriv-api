package BOM::WebSocketAPI::v3::Wrapper::Transaction;

use strict;
use warnings;

use BOM::RPC::v3::Transaction;
use BOM::WebSocketAPI::v3::Wrapper::System;

sub buy {
    my ($c, $args) = @_;

    my $contract_parameters = BOM::WebSocketAPI::v3::Wrapper::System::forget_one($c, $args->{buy})
        or return $c->new_error('buy', 'InvalidContractProposal', $c->l("Unknown contract proposal"));

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c, 'buy',
        sub {
            my $response = shift;
            if (exists $response->{error}) {
                return $c->new_error('buy', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type => 'buy',
                    buy      => $response,
                };
            }
        },
        {
            args                => $args,
            client_loginid      => $c->stash('loginid'),
            source              => $c->stash('source'),
            contract_parameters => $contract_parameters
        });

    return;
}

sub sell {
    my ($c, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c, 'sell',
        sub {
            my $response = shift;
            if (exists $response->{error}) {
                return $c->new_error('sell', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type => 'sell',
                    sell     => $response,
                };
            }
        },
        {
            args           => $args,
            client_loginid => $c->stash('loginid'),
            source         => $c->stash('source')});
    return;
}

1;
