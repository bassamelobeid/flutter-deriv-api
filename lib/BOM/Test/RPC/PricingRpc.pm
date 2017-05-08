package BOM::Test::RPC::PricingRpc;
use BOM::Test::RPC::Service;
use strict;
use warnings;

my $service;

BEGIN {
    if ($ENV{PRICING_RPC_URL}) {
        $service = BOM::Test::RPC::Service->new({
            name   => 'pricing-rpc',
            url    => $ENV{PRICING_RPC_URL},
            script => '/home/git/regentmarkets/cpan/local/bin/hypnotoad /home/git/regentmarkets/bom-pricing/bin/binary_pricing_rpc.pl'
        });
        $service->start_rpc_if_not_running;
    }
}

END {
    if ($service) {
        $service->stop_rpc;
    }
}

1;

