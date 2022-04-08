use strict;
use warnings;

use BOM::Test::CheckSyntax;

my @skipped_files = ('lib/BOM/Product/ContractValidator.pm', 'lib/BOM/Product/ContractVol.pm', 'lib/BOM/Product/ContractPricer.pm',);
BOM::Test::CheckSyntax::check_syntax_on_diff(@skipped_files);
done_testing();
