#!/etc/rmg/bin/perl

use strict;
use warnings;
use FindBin;
# load this file to force MOJO::JSON to use JSON::MaybeXS
use MOJO::JSON::MaybeXS;
use lib "$FindBin::Bin/../lib";

# There does not appear to be any specific handling for
# output layers in Mojolicious::Commands, so we need to
# set this ourselves.
binmode STDERR, ':encoding(UTF-8)';

# Start command line interface for application
require Mojolicious::Commands;
Mojolicious::Commands->start_app('Binary::WebSocketAPI');

