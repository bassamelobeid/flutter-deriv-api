#!/usr/bin/perl -I../../../lib

use strict;
use warnings;

use Test::More (tests => 9);
use Test::NoWarnings;
use Test::Exception;

use BOM::System::Types;

# Define a simple package that will succeed or fail
# when constructed with certain type values
package TypeTester;

use Moose;
use BOM::System::Types qw( bom_email_address );

has 'test_email_address' => (
    is  => 'rw',
    isa => 'bom_email_address',
);

has 'test_email_address_array' => (
    is  => 'rw',
    isa => 'ArrayRef[bom_email_address]',
);

no Moose;
__PACKAGE__->meta->make_immutable;

package main;

# Test email address variants
foreach my $i (qw/ nick@marden.org Nick@MARDEN.org this-is-a-valid-email-address@foo.co.uk/) {
    lives_ok { TypeTester->new(test_email_address => $i); } "Able to instantiate bom_email_address $i";
}

foreach my $i (qw/ user@missingtld someone@something. user@ .addresses-cannot-start-with-dots@foo.com/) {
    throws_ok { TypeTester->new(test_email_address => $i); } qr/Attribute \(test_email_address\) does not pass the type constraint/,
        'Died (as expected) instantiating invalid bom_email_address ' . $i;
}

lives_ok {
    TypeTester->new(test_email_address_array => [qw/ nick@marden.org nick@regentmarkets.com /]);
}
'Able to validate an array of email addresses';

1;
