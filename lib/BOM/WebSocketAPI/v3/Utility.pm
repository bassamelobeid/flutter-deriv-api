package BOM::WebSocketAPI::v3::Utility;

use strict;
use warnings;

sub create_error {
    my ($code, $message, $details) = @_;
    return {
        error => {
            code    => $code,
            message => $message,
            $details ? (details => $details) : ()}};
}
