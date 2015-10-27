use Test::More tests => 1;
use strict;
use warnings;

if (my $r =
    `git grep BOM:: | grep -v -e BOM::Test -e BOM::Platform -e BOM::System -e BOM::Feed -e BOM::Market -e BOM::Database -e BOM::Product -e BOM::Utility:: -e BOM::WebSocketAPI`
    )
{
    print $r;
    ok 0, "Wrong strucutre dependency $r";
} else {
    ok 1, "Strucutre dependency is OK";
}
