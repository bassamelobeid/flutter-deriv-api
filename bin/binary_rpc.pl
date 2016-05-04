#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN {
  my $orig=\&YAML::XS::LoadFile;
  *YAML::XS::LoadFile=sub {
    my ($package, $file, $line) = caller;
    warn "$$: loading @_ at $file $line";
    return $orig->(@_);
  }
}

# Start command line interface for application
require Mojolicious::Commands;
Mojolicious::Commands->start_app('BOM::RPC');

