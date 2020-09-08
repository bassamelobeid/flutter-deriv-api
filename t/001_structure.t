use Test::More tests => 2;
use strict;
use warnings;

my $cmd = q{git grep BOM:: | grep -v -P -e '^[^:]*:\s*#' | grep -v -e BOM::Config};
if (my $r = `$cmd`) {
    print $r;
    ok 0, "Wrong structure dependency $r";
} else {
    ok 1, "Structure dependency is OK";
}
