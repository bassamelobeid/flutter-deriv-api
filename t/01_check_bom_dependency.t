use strict;
use warnings;
use Test::More;
use BOM::Test::CheckSyntax qw(check_bom_dependency);

check_bom_dependency();

my $result = `git grep BOM::Rules -- lib ':(exclude)lib/BOM/Platform/CryptoCashier'`;
ok(!$result, 'BOM::Rules can only use in CryptoCashier') or diag($result);

done_testing();
