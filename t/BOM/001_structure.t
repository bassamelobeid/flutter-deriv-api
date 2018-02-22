use Test::More tests => 2;
use strict;
use warnings;
use Test::Warnings;

if (my $r =
    `git grep -E '^(use|require) BOM::' | grep -v -e BOM::Test -e BOM::Platform -e BOM::User -e BOM::Feed -e BOM::Market -e BOM::Database -e BOM::RPC -e BOM::Populator -e BOM::MT5 -e BOM::Transaction -e BOM::Product::ContractFactory -e BOM::Pricing`
    )
{
    print $r;
    ok 0, "Wrong structure dependency $r";
} else {
    ok 1, "Structure dependency is OK";
}
