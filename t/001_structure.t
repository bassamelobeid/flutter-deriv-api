use Test::More tests => 2;
use strict;
use warnings;
use Test::Warnings;

# list all files in git excluding t/structure.t
# then search for BOM::RPC in each of these files

if (my $r = `git grep BOM::RPC -- './*' ':(exclude)*.t'`) {
    print $r;
    ok 0, "Wrong structure dependency $r";
} else {
    ok 1, "Structure dependency is OK";
}
