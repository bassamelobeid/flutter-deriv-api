package BOM::Platform::Pricing;

use strict;
use warnings;

no indirect;

use MojoX::JSON::RPC::Client;
use feature "state";

use Try::Tiny;
use Time::HiRes ();
use JSON::MaybeXS;

use DataDog::DogStatsd::Helper qw(stats_timing stats_inc);

use BOM::Platform::Config;
use BOM::Platform::Context qw(request);

my $client = MojoX::JSON::RPC::Client->new();
# If pricing is slow, that's not ideal, but we should allow
# occasional spikes such as cache population - cancelling early
# just means we'll keep hitting the same issue
$client->ua->request_timeout(5);
# Connection, on the other hand, needs to be fast. 1 second is already
# too high.
$client->ua->connect_timeout(1);

sub call_rpc {
    my $method = shift;
    my $params = shift;

    my $url = ($ENV{PRICING_RPC_URL} || BOM::Platform::Config::node->{pricing_rpc_url}) . "/v3/$method";

    $params->{language} = request()->language;

    my $callobj = {
        id     => 1,
        method => $method,
        params => $params,
    };

    my $start = Time::HiRes::time;
    return try {

        my $res = $client->call($url, $callobj);

        if (!$res) {
            warn "No response in BOM::Platform::Pricing::call_rpc $method args " . JSON::MaybeXS->new->encode($callobj) . "\n";
            stats_inc('bom.platform.pricing.call_rpc.no_response', {tags => ['method:' . $method]});
            return {
                error => {
                    code              => 500,
                    message_to_client => 'Request unsuccessful'
                }};

        }

        if ($res->is_error) {
            warn "Error in BOM::Platform::Pricing::call_rpc $method args " . JSON::MaybeXS->new->encode($callobj) . " - " . $res->code . "\n";
            stats_inc('bom.platform.pricing.call_rpc.error', {tags => ['method:' . $method]});
            return {
                error => {
                    code              => 500,
                    message_to_client => 'Request unsuccessful'
                }};
        }

        return $res->result;
    }
    catch {
        warn "Exception in BOM::Platform::Pricing::call_rpc $method args " . JSON::MaybeXS->new->encode($callobj) . " - $_\n";
        stats_inc('bom.platform.pricing.call_rpc.exception', {tags => ['method:' . $method]});
        return {
            error => {
                code              => 500,
                message_to_client => 'Request unsuccessful'
            }};
    }
    finally {
        my $elapsed = Time::HiRes::time - $start;
        stats_timing('bom.platform.pricing.call_rpc.elapsed', int(1000 * $elapsed), {tags => ['method:' . $method]});
    };
}

1;
