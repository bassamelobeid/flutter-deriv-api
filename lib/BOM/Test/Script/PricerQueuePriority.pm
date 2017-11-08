package BOM::Test::Script::PricerQueuePriority;
use strict;
use warnings;

use BOM::Test;
use BOM::Test::Script;

my $script;

BEGIN {
    if (BOM::Test::on_qa()) {
        $script = BOM::Test::Script->new(script => '/home/git/regentmarkets/bom-pricing/bin/price_queue_priority.pl');
        $script->start_script_if_not_running;
    }
}

END {
    if ($script) {
        $script->stop_script;
    }
}

1;

