#!/etc/rmg/bin/perl

use strict;
use warnings;

use BOM::Market::Script::TickDecimator;
use Log::Any::Adapter;

Log::Any::Adapter->import(
    qw(DERIV),
    stderr    => 'json',
    log_level => 'info',
);

exit BOM::Market::Script::TickDecimator::run();

