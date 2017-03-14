use Test::More tests => 1;
use strict;
use warnings;

if (my $r = `git grep BOM::|grep -v BOM::Test|grep -v BOM::Platform|grep -v BOM::Market`) {
    print $r;
    ok 0, "Wrong structure dependency $r";
} else {
    ok 1, "Strucutre dependency is OK";
}
