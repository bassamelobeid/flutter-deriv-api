#!/etc/rmg/bin/perl

use strict;
use warnings;

use FindBin;
BEGIN { unshift @INC, "$FindBin::Bin/../lib" }

use Log::Any::Adapter 'DERIV',
    log_level => 'warn',
    stderr    => 'json';

# Start command line interface for application
require Mojolicious::Commands;
Mojolicious::Commands->start_app('BOM::MyAffiliatesApp');

