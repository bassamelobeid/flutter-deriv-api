#!/usr/bin/env perl

use strict;
use warnings;

use FindBin;
BEGIN {
    unshift @INC, "$FindBin::Bin/../lib";
    unshift @INC, '/home/git/regentmarkets/bom-app/lib';
    unshift @INC, '/home/git/regentmarkets/bom-web/lib';
};

# Start command line interface for application
require Mojolicious::Commands;
Mojolicious::Commands->start_app('BOM::WebSocketAPI');

