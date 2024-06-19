#!/etc/rmg/bin/perl
use strict;
use warnings;
use Log::Any::Adapter 'DERIV';

use BOM::Backoffice::Script::UpdateTradingStrategyData;
exit BOM::Backoffice::Script::UpdateTradingStrategyData::run;
