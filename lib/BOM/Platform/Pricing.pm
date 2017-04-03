package BOM::Platform::Pricing;

use strict;
use warnings;
use MojoX::JSON::RPC::Client;
use feature "state";

use BOM::Platform::Config;
use BOM::Platform::Context qw (request);

sub call_rpc {
    my $method = shift;
    my $params = shift;

    state $client = MojoX::JSON::RPC::Client->new();
    $client->ua->request_timeout(10);
    my $url = BOM::Platform::Config::node->{pricing_rpc_url} . "/v3/$method";

    $params->{language} = request()->language;

    my $callobj = {
        id     => 1,
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
