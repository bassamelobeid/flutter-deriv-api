use strict;
use warnings;
use Test::More;
use BOM::Test::CheckSyntax qw(check_bom_dependency);

# pass the module like `BOM::User` in @dependency if need
my @dependency = qw(
    BOM::Config
    BOM::Database
    BOM::Platform
    BOM::Transaction
    BOM::User
    BOM::Pricing
    BOM::MarketData
    BOM::MT5
    BOM::Rules
    BOM::TradingPlatform
    BOM::Product
    BOM::MyAffiliates
);
check_bom_dependency(@dependency);

done_testing();
