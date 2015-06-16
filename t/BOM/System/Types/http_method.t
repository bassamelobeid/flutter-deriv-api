#!/usr/bin/perl -I../../../lib

use strict;
use warnings;

use Test::More (tests => 4);
use Test::NoWarnings;
use Test::Exception;
use BOM::System::Types;

# Define a simple package that will succeed or fail
# when constructed with certain type values
package TypeTester;

use Moose;
use BOM::System::Types qw( bom_http_method );

has 'test_http_method' => (
    is  => 'rw',
    isa => 'bom_http_method',
);

no Moose;
__PACKAGE__->meta->make_immutable;

package main;

# Test http_method
foreach my $c (qw(GET POST)) {
    lives_ok { TypeTester->new(test_http_method => $c); } "Able to instantiate bom_http_method $c";
}
throws_ok { TypeTester->new(test_http_method => 'FOO'); } qr/Attribute \(test_http_method\) does not pass the type constraint/,
    'Died (as expected) instantiating invalid bom_http_method "FOO"';

1;
