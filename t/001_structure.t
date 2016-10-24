use Test::More tests => 1;
use strict;
use warnings;

if (my $r = `git grep "BOM::[A-Za-z]"`) {
    print $r;
    ok 0, "Wrong structure dependency $r";
} else {
    ok 1, "Structure dependency is OK";
}
