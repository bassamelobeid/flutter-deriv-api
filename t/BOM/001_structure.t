use Test::More tests => 1;
use strict;
use warnings;

if (my $r =
    `git grep BOM:: | grep -v '^t/' | grep -v -e BOM::Test -e BOM::WebSocketAPI -e BOM::Platform -e BOM::System -e BOM::Database -e BOM::RPC::v3`
    )
{
    print $r;
    ok 0, "Wrong structure dependency $r";
} else {
    ok 1, "Structure dependency is OK";
}
