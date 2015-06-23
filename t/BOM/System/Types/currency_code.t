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
use BOM::System::Types qw( bom_currency_code );

has 'test_currency_code' => (
    is  => 'rw',
    isa => 'bom_currency_code',
);

no Moose;
__PACKAGE__->meta->make_immutable;

package main;

# Test currency
foreach my $c (qw(AUD EUR GBP USD)) {
    lives_ok { TypeTester->new(test_currency_code => $c); } "Able to instantiate bom_currency $c";
}
throws_ok { TypeTester->new(test_currency_code => 'FOO') } qr/Attribute \(test_currency_code\) does not pass the type constraint/,
    'Died (as expected) instantiating invalid bom_currency_code "FOO"';

1;
