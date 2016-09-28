#!/etc/rmg/bin/perl

use strict;
use warnings;

# Define a simple package that will succeed or fail
# when constructed with certain type values
package TypeTester;
use Moose;
use BOM::Market::Types qw( bom_surface_type );

has surface_type => (
    is  => 'ro',
    isa => 'bom_surface_type',
);

no Moose;
__PACKAGE__->meta->make_immutable;

package main;

use Test::More (tests => 3);
use Test::Exception;

#use BOM::Market::Types;

lives_ok { TypeTester->new(surface_type => 'delta') } 'delta';
lives_ok { TypeTester->new(surface_type => 'moneyness') } 'moneyness';

throws_ok { TypeTester->new(surface_type => 'hypercubicquasiphi') } qr/Attribute \(surface_type\) does not pass the type constraint/,
    'invalid surface type';

1;
