#!/usr/bin/perl

use strict;
use warnings;

# Define a simple package that will succeed or fail
# when constructed with certain type values
package TypeTester;
use Moose;
use Date::Utility;
use BOM::System::Types qw( bom_cutoff_code );

has date => (
    is      => 'ro',
    isa     => 'bom_date_object',
    coerce  => 1,
    default => sub { Date::Utility->new },
);

no Moose;
__PACKAGE__->meta->make_immutable;

package main;

use Test::More (tests => 3);
use Test::NoWarnings;
use Test::Exception;

use BOM::System::Types;

lives_ok { TypeTester->new(date => time) } 'Can coerce epoch into Date::Utility.';
throws_ok { TypeTester->new(date => 'yabadabado') } qr/Invalid datetime format/, 'Cannot coerce junk string into Date::Utility.';

1;
