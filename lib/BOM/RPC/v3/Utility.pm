package BOM::RPC::v3::Utility;

use strict;
use warnings;

use BOM::Platform::Context qw (localize);

sub create_error {
    my $args = shift;
    return {
        error => {
            code              => $args->{code},
            message_to_client => $args->{message_to_client},
            $args->{message} ? (message => $args->{message}) : (),
            $args->{details} ? (details => $args->{details}) : ()}};
}

sub permission_error {
    return create_error({
            code              => 'PermissionDenied',
            message_to_client => localize('Permission denied.')});
}

sub ping {
    return 'pong';
}

sub server_time {
    return time;
}

1;
