package BOM::Test::Script::NotifyPub;
use strict;
use warnings;

use BOM::Test;
use BOM::Test::Script;

my $script;

BEGIN {
    if (BOM::Test::on_qa()) {
        $script = BOM::Test::Script->new(script => '/home/git/regentmarkets/bom-platform/bin/notify_pub.pl');
        $script->start_script;
    }
}

END {
    if ($script) {
        $script->stop_script;
    }
}

1;

