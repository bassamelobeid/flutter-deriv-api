#!/etc/rmg/bin/perl

use strict;
use warnings;
use BOM::Product::Script::UpdateHighLowWindows;

#Update high and low of symbols for predefined periods.
exit BOM::Product::Script::UpdateHighLowWindows->run;
