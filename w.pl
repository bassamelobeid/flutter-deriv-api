
use strict;
use warnings;

use Try::Tiny;


my $contract;
my $error;

try { die "55555"; $contract = 0; }
catch { $error = 1; };

print "[$error].....\n\n";


