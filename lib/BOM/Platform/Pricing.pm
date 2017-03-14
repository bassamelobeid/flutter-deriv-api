package BOM::Platform::Pricing;

use strict;
use warnings;
use JSON::RPC::Client;
use feature "state";
use YAML::XS;

use BOM::Platform::Config;

sub call_rpc {
    my $method = shift;
    my $params = shift;

    state $client = new JSON::RPC::Client;
    $client->ua->timeout(5);
    my $url = BOM::Platform::Config::node->{pricing_rpc_url};

    my $callobj = {
        method => $method,
        params => $params,
    };

    my $res = $client->call($uri, $callobj);

    if (!$res or $res->is_error) {
        return {
            error => {
                code              => 500,
                message_to_client => 'Request unsuccessful'
            }}

    } else {
        return $res->result;
    }
}

1;
