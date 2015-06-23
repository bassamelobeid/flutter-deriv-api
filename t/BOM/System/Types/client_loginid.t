#!/usr/bin/perl -I../../../lib

use strict;
use warnings;

use Test::More (tests => 8);
use Test::NoWarnings;
use Test::Exception;
use BOM::System::Types;

# Define a simple package that will succeed or fail
# when constructed with certain type values
package TypeTester;

use Moose;
use BOM::System::Types qw( bom_client_loginid );

has 'test_client_loginid' => (
    is  => 'rw',
    isa => 'bom_client_loginid',
);

no Moose;
__PACKAGE__->meta->make_immutable;

package main;

# Test client_loginid
foreach my $c (qw(CR1234 MLT54321 MX1010 VRTN123)) {
    lives_ok { TypeTester->new(test_client_loginid => $c); } "Able to instantiate bom_client_loginid $c";
}
throws_ok { TypeTester->new(test_client_loginid => 'FOO') } qr/Attribute \(test_client_loginid\) does not pass the type constraint/,
    'Died (as expected) instantiating invalid bom_client_loginid "FOO"';
throws_ok { TypeTester->new(test_client_loginid => 'CR12') } qr/Attribute \(test_client_loginid\) does not pass the type constraint/,
    'Died (as expected) instantiating invalid bom_client_loginid "CR121"';
throws_ok { TypeTester->new(test_client_loginid => 'VRTN11') } qr/Attribute \(test_client_loginid\) does not pass the type constraint/,
    'Died (as expected) instantiating invalid bom_client_loginid "VRTN11"';

1;
