package BOM::Test::RPC::BomRpc;
use strict;
use warnings;

use BOM::Test::RPC::Service;
use strict;
use warnings;

BEGIN {
    if ($ENV{RPC_URL}) {
        my $service = BOM::Test::RPC::Service->new({
            url    => $ENV{RPC_URL},
            script => '/home/git/regentmarkets/bom-rpc/bin/binary_rpc.pl'
        });
        $service->start_rpc_if_not_running;
    }
}

1;

