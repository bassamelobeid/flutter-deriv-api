use Test::More tests => 2;
use strict;
use warnings;
use Test::Warnings;

my $r;
if ($r = `git grep BOM::|grep -v -e BOM::Test -e BOM::Database -e BOM::Platform -e BOM::Rules -e BOM::Config -e BOM::User`) {
    print $r;
    ok 0, "Wrong structure dependency $r";
} elsif ($r = `git grep BOM::Rules -- './*' ':(exclude)lib/BOM/Platform/CryptoCashier/*' ':(exclude)*.t'`)
{    # Exclude CryptoCashier packages because they handle high-level operations
    print $r;
    ok 0, "Wrong structure dependency $r - Rule engine cannot be imported in any bom-platform module, except test scripts.";
} else {
    ok 1, "Structure dependency is OK";
}
