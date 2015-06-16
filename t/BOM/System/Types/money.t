#!/usr/bin/perl -I../../../lib

use strict;
use warnings;

use Test::More (tests => 18);
use Test::NoWarnings;
use Test::Exception;
use BOM::System::Types;

# Define a simple package that will succeed or fail
# when constructed with certain type values
package TypeTester;

use Moose;
use BOM::System::Types qw( bom_money );

has 'test_money' => (
    is  => 'rw',
    isa => 'bom_money',
);

no Moose;
__PACKAGE__->meta->make_immutable;

package main;

# Test money
foreach my $i (qw(10.12 0.45 .53 1000 0.5 -17 -17.5 -17.50 +0 +0.1 +0.10 )) {
    lives_ok { TypeTester->new(test_money => $i); } "Able to instantiate bom_money $i";
}
foreach my $i (qw(10.123 0. X 100.0.0 -0.123 +0.101 )) {
    throws_ok { TypeTester->new(test_money => $i); } qr/Attribute \(test_money\) does not pass the type constraint/,
        'Died (as expected) instantiating invalid bom_money ' . $i;
}

1;
