package BOM::Test::Script::RpcRedis;
use strict;
use warnings;

BEGIN {
    local $ENV{NO_PURGE_REDIS} = 1;
    require BOM::Test;
}
use BOM::Test::Script;

my $script;

BEGIN {
    if (not BOM::Test::on_production()) {
        $script = BOM::Test::Script->new(
            script => '/home/git/regentmarkets/bom-rpc/bin/binary_rpc_redis.pl',
            args   => [qw/ --workers 1 /]);

        die 'Failed to start test pricer queue' unless $script->start_script_if_not_running;
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

