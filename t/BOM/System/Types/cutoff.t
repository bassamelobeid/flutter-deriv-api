#!/usr/bin/perl

use strict;
use warnings;

# Define a simple package that will succeed or fail
# when constructed with certain type values
package TypeTester;
use Moose;
use BOM::System::Types qw( bom_cutoff_code );

has cutoff_code => (
    is  => 'ro',
    isa => 'bom_cutoff_code',
);

no Moose;
__PACKAGE__->meta->make_immutable;

package main;

use Test::More (tests => 8);
use Test::NoWarnings;
use Test::Exception;

use BOM::System::Types;

lives_ok { TypeTester->new(cutoff_code => 'New York 10:00') } 'New York 10:00';
lives_ok { TypeTester->new(cutoff_code => 'UTC 23:59') } 'UTC 23:59';

throws_ok { TypeTester->new(cutoff_code => 'New York 10') } qr/Attribute \(cutoff_code\) does not pass the type constraint/,
    'Invalid: New York 10 (no minutes).';
throws_ok { TypeTester->new(cutoff_code => 'New York 10am') } qr/Attribute \(cutoff_code\) does not pass the type constraint/,
    'Invalid: New York 10am (no minutes, meridiem given).';
throws_ok { TypeTester->new(cutoff_code => 'NEW YORK 10:00') } qr/Attribute \(cutoff_code\) does not pass the type constraint/,
    'Invalid: NEW YORK 10:00 (all caps city).';
throws_ok { TypeTester->new(cutoff_code => 'new york 10:00') } qr/Attribute \(cutoff_code\) does not pass the type constraint/,
    'Invalid: new york 10:00 (all lower-case city).';
throws_ok { TypeTester->new(cutoff_code => 'Aberdeen 10:00') } qr/Attribute \(cutoff_code\) does not pass the type constraint/,
    'Invalid: Aberdeen 10:00 (unsupported city).';

1;
