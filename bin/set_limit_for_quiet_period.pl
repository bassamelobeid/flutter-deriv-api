#!/usr/bin/perl

use strict;
use warnings;
use Log::Any::Adapter 'DERIV';
use BOM::Backoffice::Script::SetLimitForQuietPeriod;

exit BOM::Backoffice::Script::SetLimitForQuietPeriod->new->run;
