#!/usr/bin/perl -I../../../lib

use strict;
use warnings;

use Test::More (tests => 8);
use Test::Exception;
use Test::NoWarnings;
use BOM::System::Types;

# Define a simple package that will succeed or fail
# when constructed with certain type values
package TypeTester;

use Moose;
use BOM::System::Types qw( bom_ipv4_host_address );

has 'test_ipv4_host_address' => (
    is  => 'rw',
    isa => 'bom_ipv4_host_address',
);

no Moose;
__PACKAGE__->meta->make_immutable;

package main;

# Test ipv4_address
foreach my $i (qw(1.2.3.4 251.252.253.254 0.0.0.0)) {
    lives_ok { TypeTester->new(test_ipv4_host_address => $i); } "Able to instantiate bom_ipv4_host_address $i";
}
foreach my $i (qw(1.2.3.0 255.255.255.255 1..2.3 256.1.2.3)) {
    throws_ok { TypeTester->new(test_ipv4_host_address => $i); } qr/Attribute \(test_ipv4_host_address\) does not pass the type constraint/,
        'Died (as expected) instantiating invalid bom_ipv4_host_address ' . $i;
}

1;
