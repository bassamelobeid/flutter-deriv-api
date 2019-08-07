package BOM::Test::Script::RpcQueue;
use strict;
use warnings;

use BOM::Test;
use BOM::Test::Script;
use BOM::Config::RedisReplicated;

my $script;

BEGIN {
    my $socket_path = '/var/run/bom-rpc/binary_jobqueue_worker.sock';
    my $script_path = '/home/git/regentmarkets/bom-rpc/bin/binary_jobqueue_worker.pl';

    if (!BOM::Test::on_production()) {
        $script = BOM::Test::Script->new(
            script => $script_path,
            args   => "--testing --socket $socket_path --redis $ENV{BOM_TEST_REDIS_RPC_QUEUES} --foreground",
        );
        $script->start_script_if_not_running;
    }
}

END {
    if ($script) {
        $script->stop_script;
    }
}

1;

