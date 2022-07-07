use strict;
use warnings;
use Test::More;
use BOM::Test::CheckSyntax qw(check_bom_dependency);

# pass the module like `BOM::User` in @dependency if need
my @dependency = qw(
    BOM::Config
    BOM::User
    BOM::Database
    BOM::Platform
    BOM::Transaction
    BOM::Product
    BOM::MT5
    BOM::MyAffiliates
    BOM::Rules
);

check_bom_dependency(@dependency);

done_testing();
