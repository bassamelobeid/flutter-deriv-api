use Test::More tests => 1;
use strict;
use warnings;

if (my $r = `git grep BOM:: | grep -v -e BOM::Utility -e BOM::Test -e BOM::Database -e BOM::System'`) {
	print $r;
    ok 0, "Wrong strucutre dependency $r";
} else {
    ok 1, "Strucutre dependency is OK";
}
