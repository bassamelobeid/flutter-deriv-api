use Test::More tests => 2;
use Test::Warnings;
use strict;
use warnings;

if (my $r = `git grep BOM::|grep -v BOM::Test|grep -v Test::BOM|grep -v BOM::Platform|grep -v BOM::Config|grep -v BOM::Market|grep -v BOM::Product`) {
    print $r;
    ok 0, "Wrong structure dependency $r";
} else {
    ok 1, "Structure dependency is OK";
}
