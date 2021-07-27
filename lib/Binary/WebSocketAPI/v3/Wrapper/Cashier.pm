package Binary::WebSocketAPI::v3::Wrapper::Cashier;

use strict;
use warnings;
use Log::Any qw($log);

sub log_paymentagent_error {
    my ($c, $response) = @_;
    $log->info($response->{error}->{message}) if (exists $response->{error}->{message});
    return;
}

sub get_response_handler {
    my ($rpc_method) = @_;

    return sub {
        my ($rpc_response, $api_response) = @_;
        if (not(exists $rpc_response->{error})) {
            $api_response = {
                %$api_response,
                $rpc_method => delete $rpc_response->{status},
                %$rpc_response
            };
        }
        return $api_response;
    };
}

1;
