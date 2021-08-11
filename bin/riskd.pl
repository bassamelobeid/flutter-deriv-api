#!/etc/rmg/bin/perl
use strict;
use warnings;
use Log::Any::Adapter ('DERIV', log_level => $ENV{RISKD_LOG_LEVEL} // 'info');
use BOM::Backoffice::Script::Riskd;
use Metrics::Any::Adapter qw(DogStatsd);

exit BOM::Backoffice::Script::Riskd->new()->run;
