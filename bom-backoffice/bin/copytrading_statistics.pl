#!/etc/rmg/bin/perl
use strict;
use warnings;
use Log::Any::Adapter 'DERIV';

use BOM::Backoffice::Script::CopyTradingStatistics;

exit BOM::Backoffice::Script::CopyTradingStatistics::run();
