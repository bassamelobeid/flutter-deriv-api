#!/etc/rmg/bin/perl

package main;
use strict;
use BOM::Script::RiskScenarioAnalysis;

exit BOM::Script::RiskScenarioAnalysis->new->run;

