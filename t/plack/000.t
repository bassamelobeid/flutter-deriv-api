#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

# This is here only to save time by resetring the test database once here for a run of prove t/*.t.
# Unless it's been really scrambled, there's no need to reset it at the top of each paymentapi test.

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

ok(1, 'test database has been reset');

done_testing();

