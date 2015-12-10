package BOM::WebSocketAPI::v3::Wrapper::Offerings;

use strict;
use warnings;

use BOM::WebSocketAPI::v3::Offerings;

sub contracts_for {
    my ($c, $args) = @_;
    my $response = BOM::WebSocketAPI::v3::Offerings::contracts_for($args);
    if ($response->{error}) {
        return $c->new_error('contracts_for', $response->{error}->{code}, $response->{error}->{message_to_client});
    } else {
        return {
            msg_type      => 'contracts_for',
            contracts_for => $response
        };
    }
}

1;
