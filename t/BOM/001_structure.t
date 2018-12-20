use Test::More tests => 2;
use strict;
use warnings;
use Test::Warnings;

if (my $r = `git grep BOM:: lib | grep -v -e BOM::Test -e BOM::Database -e BOM::Config`) {
    print $r;
    ok 0, "Wrong structure dependency $r";
} else {
    ok 1, "Structure dependency is OK";
}
