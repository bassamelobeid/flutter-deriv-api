package BOM::Test::Script::RpcRedis;
use strict;
use warnings;

BEGIN {
    local $ENV{NO_PURGE_REDIS} = 1;
    require BOM::Test;
}
use BOM::Test::Script;

my $script;

sub new {
    my ($self, $category) = @_;
    $category //= 'general';

    if (not BOM::Test::on_production()) {
        $script = BOM::Test::Script->new(
            script => '/home/git/regentmarkets/bom-rpc/bin/binary_rpc_redis.pl',
            args   => [qw/ --workers 1 --category /, $category]);

        die 'Failed to start rpc redis consumer.' unless $script->start_script_if_not_running;
        return $script;
    }
}

END {
    if ($script) {
        $script->stop_script;
    }
}

1;
