#!/usr/bin/perl -I../../../lib

use strict;
use warnings;

use Test::More (tests => 6);
use Test::NoWarnings;
use Test::Exception;
use BOM::System::Types;

# Define a simple package that will succeed or fail
# when constructed with certain type values
package TypeTester;

use Moose;
use BOM::System::Types qw( bom_signal_name );

has 'test_signal_name' => (
    is  => 'rw',
    isa => 'bom_signal_name',
);

no Moose;
__PACKAGE__->meta->make_immutable;

package main;

# Test timestamp
my @valid = qw( ABRT TERM INT QUIT );
foreach my $t (@valid) {
    lives_ok { TypeTester->new(test_signal_name => $t); } "Able to instantiate bom_signal_name $t";
}

my @invalid = qw( foo );
foreach my $t (@invalid) {
    throws_ok { TypeTester->new(test_signal_name => $t); } qr/Attribute \(test_signal_name\) does not pass the type constraint/,
        'Died (as expected) instantiating invalid bom_signal_name ' . $t;
}

1;
