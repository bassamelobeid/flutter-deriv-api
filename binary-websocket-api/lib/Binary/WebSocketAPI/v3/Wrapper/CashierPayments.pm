package Binary::WebSocketAPI::v3::Wrapper::CashierPayments;

use strict;
use warnings;

=head1 NAME

Binary::WebSocketAPI::v3::Wrapper::CashierPayments

=head1 DESCRIPTION

Provides subscription hooks for updates on the cashier payments.

=cut

no indirect;

use Binary::WebSocketAPI::v3::Subscription;
use Binary::WebSocketAPI::v3::Subscription::CashierPayments;

=head2 subscribe_cashier_payments

Takes the following arguments

=over 4

=item * C<$rpc_response> - message returned by rpc call.

=item * C<$req_storage> - JSON message containing a C<cashier_payment> request as received through websocket.

=back

Returns a JSON message, containing C<$rpc_response> and subscription id.

=cut

sub subscribe_cashier_payments {
    my ($c, $rpc_response, $req_storage) = @_;

    my $args     = $req_storage->{args};
    my $msg_type = $req_storage->{msg_type};

    if ($rpc_response->{error}) {
        return $c->new_error($msg_type, $rpc_response->{error}{code}, $rpc_response->{error}{message_to_client});
    }

    my $result = {
        msg_type  => $msg_type,
        $msg_type => $rpc_response,
        defined $args->{req_id} ? (req_id => $args->{req_id}) : (),
    };

    return $result unless $args->{subscribe};

    my $transaction_type = $args->{transaction_type};
    my $sub              = Binary::WebSocketAPI::v3::Subscription::CashierPayments->new(
        c                => $c,
        args             => $args,
        loginid          => $args->{loginid} // $c->stash('loginid'),
        transaction_type => $transaction_type,
    );

    if ($sub->already_registered) {
        return $c->new_error($msg_type, 'AlreadySubscribed',
            $c->l('You are already subscribed to cashier payments with [_1]: [_2].', 'transaction_type', $transaction_type));
    }

    $sub->register;
    $sub->subscribe;
    $result->{subscription}{id} = $sub->uuid;
    return $result;
}

1;
