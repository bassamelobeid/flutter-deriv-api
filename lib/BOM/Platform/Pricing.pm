package BOM::Platform::Pricing;

use strict;
use warnings;
use MojoX::JSON::RPC::Client;
use feature "state";

use BOM::Platform::Config;

sub call_rpc {
    my $method = shift;
    my $params = shift;

    state $client = MojoX::JSON::RPC::Client->new();
    $client->ua->timeout(5);
    my $url = BOM::Platform::Config::node->{pricing_rpc_url};

    my $callobj = {
        method => $method,
        params => $params,
    };

    my $res = $client->call($url, $callobj);

    if (!$res || $res->is_error) {
        return {
            error => {
                code              => 500,
                message_to_client => 'Request unsuccessful'
            }};
    } else {
        return $res->result;
    }
}

1;
