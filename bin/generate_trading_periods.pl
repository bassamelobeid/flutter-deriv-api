#!/etc/rmg/bin/perl
use strict;
use warnings;

use BOM::Product::Script::GenerateTradingPeriods;

#This daemon generates predefined trading periods for selected underlying symbols at XX:45 and XX:00
exit BOM::Product::Script::GenerateTradingPeriods->run;
