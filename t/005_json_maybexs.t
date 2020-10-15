use strict;
use warnings;
use Test::More;
use Test::Warnings qw(:no_end_test);
use BOM::Test::CheckJsonMaybeXS qw(check_JSON_MaybeXS);

# lib/BOM/User/Client/Payments.pm is skipped because it is a legacy module and will die when we compile it.
check_JSON_MaybeXS(skip_files => [qw(lib/BOM/User/Client/Payments.pm)]);

done_testing();
