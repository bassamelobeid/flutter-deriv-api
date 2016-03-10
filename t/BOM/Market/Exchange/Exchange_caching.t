use strict;
use warnings;

use Test::MockTime qw(:all);
use Test::More;
use Test::FailWarnings;
use BOM::Market::Exchange;
use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );

BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => 'GBP'});

# check that cache is flushed after exchanges.yml is touched
my $LSE = BOM::Market::Exchange->new('LSE');
isa_ok $LSE, "BOM::Market::Exchange";
my $FOREX = BOM::Market::Exchange->new('FOREX');
isnt($FOREX, $LSE, "different objects for FOREX and LSE");
my $LSE2 = BOM::Market::Exchange->new('LSE');
is $LSE2, $LSE, "new returned the same M::E object";

set_relative_time(400);
note "Force Cache timeout";
my $LSE4 = BOM::Market::Exchange->new('LSE');
isnt($LSE4, $LSE, "new returned new M::E object");

done_testing;
