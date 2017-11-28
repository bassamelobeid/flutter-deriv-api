package BOM::Test::Script::PricerDaemon;
use strict;
use warnings;

use BOM::Test;
use BOM::Test::Script;

my $script;

BEGIN {
    if (BOM::Test::on_qa()) {
        $script = BOM::Test::Script->new(
            script => '/home/git/regentmarkets/bom-pricing/bin/price_daemon.pl',
            args   => '--workers=1 --no-warmup=1'
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

