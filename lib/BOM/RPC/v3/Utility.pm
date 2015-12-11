package BOM::RPC::v3::Utility;

use strict;
use warnings;

sub create_error {
    my $args = shift;
    return {
        error => {
            code              => $args->{code},
            message_to_client => $args->{message_to_client},
            $args->{message} ? (message => $args->{message}) : (),
            $args->{details} ? (details => $args->{details}) : ()}};
}

sub ping {
    return 'pong';
}

sub server_time {
    return time;
}

1;
