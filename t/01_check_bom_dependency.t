use strict;
use warnings;
use Test::More;
use BOM::Test::CheckSyntax qw(check_bom_dependency);

my @dependency = qw(
    BOM::Config
    BOM::Database
    BOM::User
    BOM::Platform
    BOM::Product
    BOM::Transaction
    BOM::CTC
    BOM::MarketData
    BOM::RPC
    BOM::Rules
);

check_bom_dependency(@dependency);

done_testing();
