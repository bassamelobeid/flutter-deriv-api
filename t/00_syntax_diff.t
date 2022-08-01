use strict;
use warnings;
use Test::More;
use BOM::Test::CheckSyntax qw(check_syntax_on_diff);

$BOM::Test::CheckSyntax::skip_tidy = 1;
my @skip_files = qw(lib/BOM/Config/AccountType.pm lib/BOM/Config/AccountType/Group.pm lib/BOM/Config/AccountType/Category.pm);

check_syntax_on_diff(@skip_files);

done_testing();
