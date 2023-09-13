#!/etc/rmg/bin/perl

use strict;
use warnings;

use BOM::Market::Script::FeedDecimate;
use Log::Any::Adapter;

Log::Any::Adapter->import(
    qw(DERIV),
    stderr    => 'json',
    log_level => 'info',
);

exit BOM::Market::Script::FeedDecimate::run();

