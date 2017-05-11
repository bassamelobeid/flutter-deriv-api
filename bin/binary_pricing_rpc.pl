#!/etc/rmg/bin/perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use if $ENV{MOCKTIME}, 'BOM::Test::Time';

# Start command line interface for application
require Mojolicious::Commands;
Mojolicious::Commands->start_app('BOM::Pricing::RPC');

