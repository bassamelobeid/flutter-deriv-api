#!/etc/rmg/bin/perl
use strict;
use warnings;
use BOM::Backoffice::Script::Riskd;

exit BOM::Backoffice::Script::Riskd->new({
        user  => 'nobody',
        group => 'nogroup',
    })->run;
