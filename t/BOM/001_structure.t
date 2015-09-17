use Test::More tests => 1;
use strict;
use warnings;

if (my $r = `git grep BOM::|grep -v BOM::Test|grep -v BOM::Utility|grep -v BOM::Database`) {
	print $r;
    ok 0, "Wrong strucutre dependency $r";
} else {
    ok 1, "Strucutre dependency is OK";
}





