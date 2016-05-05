#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::MockModule;
use YAML::XS;
use YAML;
use Carp qw(confess);
BEGIN {
  my $orig=\&YAML::XS::LoadFile;
  *YAML::XS::LoadFile=sub {
    my ($package, $file, $line) = caller;
    open(my $fh,">>", "/tmp/log.log");
    print $fh "$$: loading @_ at $file $line\n";
    eval {confess()};
    print $fh $@;
    close($fh);
    return $orig->(@_);
  };

  my $orig2=\&YAML::LoadFile;
  *YAML::LoadFile=sub {
    my ($package, $file, $line) = caller;
    open(my $fh,">>", "/tmp/log.log");
    print $fh "$$: loading @_ at $file $line\n";
    eval {confess()};
    print $fh $@;
    close($fh);
    return $orig2->(@_);
  }

}

# Start command line interface for application
require Mojolicious::Commands;
Mojolicious::Commands->start_app('BOM::RPC');

