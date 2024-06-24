use Test::More tests => 1;
use strict;
use warnings;

if (my $r =
    `git grep BOM:: | grep -v -e BOM::Test -e BOM::Platform -e BOM::Config -e BOM::Config -e BOM::Config -e BOM::Platform -e BOM::Config -e BOM::Config -e BOM::Config -e BOM::User -e BOM::Market -e BOM::Database -e BOM::Product -e BOM::Transaction -e BOM::RPC::v3 -e BOM::Service`
    )
{
    print $r;
    ok 0, "Wrong structure dependency $r";
} else {
    ok 1, "Structure dependency is OK";
}
