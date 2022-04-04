#!/usr/bin/env perl

use strict;
use warnings;

use FindBin;
BEGIN { unshift @INC, "$FindBin::Bin/../lib" }
use Mojolicious::Commands;
use Log::Any::Adapter qw(DERIV),
    stderr    => 'json',
    log_level => $ENV{BOM_LOG_LEVEL} // 'info';

# Start command line interface for application
Mojolicious::Commands->start_app('BOM::Platform::CryptoCashier::Iframe');

