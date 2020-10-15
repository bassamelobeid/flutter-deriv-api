use strict;
use warnings;
use Test::More;
use Test::Warnings qw(:no_end_test);
use BOM::Test::CheckJsonMaybeXS qw(check_JSON_MaybeXS);

# We skip these modules, because their package name is not same with file name.
# and they are loaded and checked already by BOM:Product::Contract
check_JSON_MaybeXS(skip_files => [qw(lib/BOM/Product/ContractVol.pm
                                     lib/BOM/Product/ContractValidator.pm
                                     lib/BOM/Product/Pricing/Engine/markup_config.yml
                                     lib/BOM/Product/ContractPricer.pm
                                )]);
done_testing();
