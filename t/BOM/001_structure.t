use Test::More tests => 2;
use strict;
use warnings;
use Test::Warnings;

if (my $r = `git grep BOM::|grep -v BOM::Test|grep -v BOM::Database|grep -v BOM::Platform | grep -v BOM::Config|grep -v BOM::Market`) {
    print $r;
    ok 0, "Wrong structre dependency $r";
} else {
    ok 1, "Structre dependency is OK";
}
