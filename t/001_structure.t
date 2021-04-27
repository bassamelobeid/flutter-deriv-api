use strict;
use warnings;

use Test::More tests => 2;
use Test::Warnings;

# Skip the module name that appear in comment lines. like the format in the following line:
# lib/BOM/Config.pm:# This is a comment line that include 'BOM::Test'
# and skip BOM::Config
my $cmd = q{git grep BOM:: | grep -v -P -e '^[^:]*:\s*#' | grep -v -e BOM::Config};
if (my $r = `$cmd`) {
    print $r;
    ok 0, "Wrong structure dependency $r";
} else {
    ok 1, "Structure dependency is OK";
}
