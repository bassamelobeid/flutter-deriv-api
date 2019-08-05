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

    my $redis = BOM::Config::RedisReplicated::get_redis_uri('rpc_queue', 'write');

    if (!BOM::Test::on_production()) {
        $script = BOM::Test::Script->new(
            script => $script_path,
            args   => "--testing --socket $socket_path --redis $redis --foreground",
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

