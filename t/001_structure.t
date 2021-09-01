use Test::More tests => 2;
use strict;
use warnings;
use Test::Warnings;

# list all files in git excluding t/structure.t
# then search for BOM::Rules in each of these files - it will result in circular dependency.

if (my $r = `git grep BOM::Rules -- './*' ':(exclude)*.t'`) {
    print $r;
    ok 0, "Wrong structure dependency $r - Rule engine cannot be imported in any bom-user module.";
} else {
    ok 1, "Structure dependency is OK";
}
