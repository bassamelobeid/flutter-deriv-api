use Test::More tests => 1;
use strict;
use warnings;

if (my $r = `git grep BOM::|egrep -v BOM::Utility|grep -v BOM::Test|egrep -v BOM::Database|egrep -v BOM::System`) {
	print $r;
    ok 0, "Wrong strucutre dependency $r";
} else {
    ok 1, "Strucutre dependency is OK";
}
