package BOM::Test::Script::PricerDaemon;
use strict;
use warnings;

BEGIN {
    local $ENV{NO_PURGE_REDIS} = 1;
    require BOM::Test;
}
use BOM::Test::Script;

my $script;

BEGIN {
    if (BOM::Test::on_qa()) {
        $script = BOM::Test::Script->new(
            script => '/home/git/regentmarkets/bom-pricing/bin/price_daemon.pl',
            args   => [qw(--workers=1 --no-warmup=1)],
        );
        die 'Failed to start test pricer daemon' unless $script->start_script_if_not_running;
    }
}

END {
    if ($script) {
        $script->stop_script;
    }
}

1;

