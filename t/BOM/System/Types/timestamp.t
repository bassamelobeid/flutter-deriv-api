#!/usr/bin/perl -I../../../lib

use strict;
use warnings;

use Test::More (tests => 12);
use Test::NoWarnings;
use Test::Exception;
use BOM::System::Types;

# Define a simple package that will succeed or fail
# when constructed with certain type values
package TypeTester;

use Moose;
use Date::Utility;
use BOM::System::Types qw( bom_timestamp );

has 'test_timestamp' => (
    is  => 'rw',
    isa => 'bom_timestamp',
);

has 'test_coerce_timestamp' => (
    is     => 'rw',
    isa    => 'bom_timestamp',
    coerce => 1,
);

no Moose;
__PACKAGE__->meta->make_immutable;

package main;

# Test timestamp
my @valid = (
    "2010-10-26T04:01:37",    "1971-11-21T16:13:04", "1971-11-21T16:13:04Z", "1971-11-21T16:13:04UTC",
    "1971-11-21T16:13:04GMT", Date::Utility->new->datetime_iso8601,
);
foreach my $t (@valid) {
    lives_ok { TypeTester->new(test_timestamp => $t); } "Able to instantiate bom_timestamp $t";
}

throws_ok { TypeTester->new(test_timestamp => Date::Utility->new) } qr/Attribute \(test_timestamp\) does not pass the type constraint/,
    'Not able to coerce a Date::Utility into a bom_timestamp without coercion turned on';

lives_ok { TypeTester->new(test_coerce_timestamp => Date::Utility->new) }
"Able to coerce a Date::Utility into a bom_timestamp with coercion turned on";

my @invalid = ("0000-00-00T00:00:00", "971-11-21T16:13:04", "1971-11-21T16:13:04 -0500",);

foreach my $t (@invalid) {
    throws_ok { TypeTester->new(test_timestamp => $t); } qr/Attribute \(test_timestamp\) does not pass the type constraint/,
        'Died (as expected) instantiating invalid bom_timestamp ' . $t;
}

1;
