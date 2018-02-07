use Test::More;
use strict;
use warnings;
use Test::Warnings;

if (my $r = `git grep "BOM::[A-Za-z]" | grep -v .proverc | grep -v README.md | grep -v -e BOM::Test`) {
    print $r;
    ok 0, "Wrong structure dependency $r";
} else {
    ok 1, "Structure dependency is OK";
}

done_testing;
