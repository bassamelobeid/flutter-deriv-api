use strict;
use warnings;
use Test::More;
use BOM::Test::CheckSyntax qw(check_bom_dependency);

# pass the module like `BOM::User` in @dependency if need
my @dependency = qw(
    BOM::Config
    BOM::User
    BOM::Database
    BOM::MarketData
    BOM::Rules
);

check_bom_dependency(@dependency);

my $result = `git grep BOM::Rules lib ':(exclude)lib/BOM/Platform/CryptoCashier'`;
ok (!$result,  'BOM::Rules can only use in CryptoCashier') or diag($result);

done_testing();
