use Test::More tests => 1;
use strict;
use warnings;

if (my $r =
    `git grep BOM:: | grep -v -e BOM::Test -e BOM::Platform -e BOM::System -e BOM::Feed -e BOM::Market -e BOM::Database -e BOM::Product -e BOM::RPC -e BOM::Populator -e BOM::Mt5`
    )
{
    print $r;
    ok 0, "Wrong structure dependency $r";
} else {
    ok 1, "Structure dependency is OK";
}
