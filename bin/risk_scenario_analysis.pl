#!/etc/rmg/bin/perl

package main;
use strict;
use BOM::Backoffice::Script::RiskScenarioAnalysis;

exit BOM::Backoffice::Script::RiskScenarioAnalysis->new->run;

