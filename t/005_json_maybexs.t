use strict;
use warnings;
use Test::More;
use Test::Warnings qw(:no_end_test);
use FindBin qw($Bin);
use lib "$Bin/lib";
use BOM::Config::Test::CheckJsonMaybeXS qw(check_JSON_MaybeXS);

check_JSON_MaybeXS();

done_testing();
