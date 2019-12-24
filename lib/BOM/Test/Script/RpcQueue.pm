package BOM::Test::Script::RpcQueue;
use strict;
use warnings;

use BOM::Test;
use BOM::Test::Script;
use BOM::Config::RedisReplicated;

my $script;

BEGIN {
    my $socket_path = '/tmp/binary_jobqueue_worker.sock';
    my $script_path = '/home/git/regentmarkets/bom-rpc/bin/binary_jobqueue_worker.pl';

    if (!BOM::Test::on_production()) {
        $script = BOM::Test::Script->new(
            script => $script_path,
            args   => "--testing --socket $socket_path --workers 1",
        );
        $script->start_script_if_not_running;
    }
}

sub get_script {
    return $script;
}

END {
    if ($script) {
        $script->stop_script;
    }
}

1;

