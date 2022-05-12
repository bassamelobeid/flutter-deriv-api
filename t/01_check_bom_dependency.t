use strict;
use warnings;
use Test::More;
use BOM::Test::CheckSyntax qw(check_bom_dependency);

# pass the module like `BOM::User` in @dependency if need
my @dependency = qw(
    BOM::Config
    BOM::User
    BOM::Database
    BOM::Product
    BOM::Transaction
    BOM::CTC
    BOM::Platform
    BOM::MyAffiliates
    BOM::OAuth
    BOM::MT5
    BOM::DualControl
    BOM::StaffPages
    BOM::Rules
);

check_bom_dependency(@dependency);

done_testing();
