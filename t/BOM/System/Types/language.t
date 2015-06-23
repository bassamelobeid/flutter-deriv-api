#!/usr/bin/perl -I../../../lib

use strict;
use warnings;

use Test::More (tests => 11);
use Test::NoWarnings;
use Test::Exception;
use BOM::System::Types;

# Define a simple package that will succeed or fail
# when constructed with certain type values
package TypeTester;

use Moose;
use BOM::System::Types qw( bom_language_code );

has 'test_language_code' => (
    is  => 'rw',
    isa => 'bom_language_code',
);

no Moose;
__PACKAGE__->meta->make_immutable;

package main;

# Test language
foreach my $c (qw(de en es fr id ja pt ru zh)) {
    lives_ok { TypeTester->new(test_language_code => $c); } "Able to instantiate bom_language $c";
}
throws_ok { TypeTester->new(test_language_code => 'cs') } qr/Attribute \(test_language_code\) does not pass the type constraint/,
    'Died (as expected) instantiating invalid bom_language_code "cs"';

1;
