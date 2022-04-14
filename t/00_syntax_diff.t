use strict;
use warnings;
use Test::More;
use BOM::Test::CheckSyntax qw(check_syntax_on_diff);

my @skip_files = qw(
    lib/BOM/Product/ContractValidator.pm
    lib/BOM/Product/ContractVol.pm
    lib/BOM/Product/ContractPricer.pm
);

check_syntax_on_diff(@skip_files);

done_testing();
