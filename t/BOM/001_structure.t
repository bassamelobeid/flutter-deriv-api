use Test::More tests => 2;
use strict;
use warnings;
use Test::Warnings;

if (my $r = `git grep BOM::|grep -v BOM::Test|grep -v BOM::Platform|grep -v BOM::Market`) {
    print $r;
    ok 0, "Wrong structure dependency $r";
} else {
    ok 1, "Structure dependency is OK";
}
