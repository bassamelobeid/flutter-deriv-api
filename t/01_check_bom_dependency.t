use strict;
use warnings;
use Test::More;
use BOM::Test::CheckSyntax qw(check_bom_dependency);

check_bom_dependency([qw(BOM::Service)]);

done_testing();
