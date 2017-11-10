#!/usr/bin/env perl
use strict;
use warnings;

use BOM::Pricing::ContractsForGenerator;

my $products = { map {$_=>1} qw/basic multi_barrier/};
die "$0 <product>" unless defined $products->{$ARGV[0]};
warn $ARGV[0];
BOM::Pricing::ContractsForGenerator::run($ARGV[0]);
