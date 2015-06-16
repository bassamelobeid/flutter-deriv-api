use strict;
use warnings;

use Test::MockTime qw(:all);
use Test::More tests => 4;
use Test::NoWarnings;

use BOM::Test::Runtime qw(:normal);
use BOM::Market::Currency;
use Date::Utility;
use File::Slurp;
use BOM::Test::Data::Utility::UnitTestCouchDB qw( :init );

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency_config',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for qw( AUD RUR );

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for (qw/AUD RUR/);

# check that cache is flushed after currencies.yml is touched
my $AUD = BOM::Market::Currency->new('AUD');
isa_ok $AUD, "BOM::Market::Currency";
my $RUR  = BOM::Market::Currency->new('RUR');
my $AUD2 = BOM::Market::Currency->new('AUD');
is $AUD2, $AUD, "new returned the same M::C object";

set_relative_time(400);
note "Force Reloading";
$RUR = BOM::Market::Currency->new('RUR');
my $AUD3 = BOM::Market::Currency->new('AUD');
isnt($AUD3, $AUD, "new returned new M::C object");

