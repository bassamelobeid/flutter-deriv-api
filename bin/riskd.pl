#!/etc/rmg/bin/perl
use strict;
use warnings;
use BOM::Script::Riskd;

exit BOM::Script::Riskd->new({
        user  => 'nobody',
        group => 'nogroup',
    })->run;
