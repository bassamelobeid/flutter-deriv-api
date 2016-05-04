#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::MockModule;
use YAML::XS;
BEGIN {
  my $orig=\&YAML::XS::LoadFile;
  *YAML::XS::LoadFile=sub {
    my ($package, $file, $line) = caller;
    open(my $fh,">>", "/tmp/log.log");
    print $fh "$$: loading @_ at $file $line\n";
    close($fh);
    return $orig->(@_);
  }
}

# Start command line interface for application
require Mojolicious::Commands;
Mojolicious::Commands->start_app('BOM::RPC');

