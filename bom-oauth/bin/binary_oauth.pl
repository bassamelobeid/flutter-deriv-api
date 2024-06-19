#!/etc/rmg/bin/perl

use strict;
use warnings;

use FindBin;
BEGIN { unshift @INC, "$FindBin::Bin/../lib" }
use Log::Any::Adapter 'DERIV',
    log_level => 'info',
    stderr    => 'json';

# Mojo will redirect STDERR without autoflush, so we should set autoflush manually
*STDERR->autoflush(1);

# Start command line interface for application
require Mojolicious::Commands;
Mojolicious::Commands->start_app('BOM::OAuth');
