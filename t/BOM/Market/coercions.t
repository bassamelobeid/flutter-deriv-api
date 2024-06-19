#!/etc/rmg/bin/perl

use strict;
use warnings;

# Define a simple package that will succeed or fail
# when constructed with certain type values
package TypeTester;
use Moose;
use Date::Utility;

has date => (
    is      => 'ro',
    isa     => 'date_object',
    coerce  => 1,
    default => sub { Date::Utility->new },
);

no Moose;
__PACKAGE__->meta->make_immutable;

package main;

use Test::More (tests => 3);
use Test::Exception;
use Test::Warnings;

use Finance::Underlying::Market::Types;

lives_ok { TypeTester->new(date => time) } 'Can coerce epoch into Date::Utility.';
throws_ok { TypeTester->new(date => 'yabadabado') } qr/Invalid datetime format/, 'Cannot coerce junk string into Date::Utility.';

1;
