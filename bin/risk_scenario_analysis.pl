#!/etc/rmg/bin/perl
use strict;
use warnings;
use Log::Any::Adapter 'DERIV';

use BOM::Backoffice::Script::RiskScenarioAnalysis;
exit BOM::Backoffice::Script::RiskScenarioAnalysis->new->run;

