#!perl -T
use 5.006;
use strict;
use warnings;
use Test::More;

plan tests => 1;

BEGIN {
    use_ok( 'Quant::Benchmark' ) || print "Bail out!\n";
}

diag( "Testing Quant::Benchmark $Quant::Benchmark::VERSION, Perl $], $^X" );
