#!/etc/rmg/bin/perl

package main;
use strict;
use warnings;

use BOM::User::Script::POIExpirationPopulator;

=head1 NAME

poi_expiration_populator.pl

=head1 DESCRIPTION

This is a SRP after script that automatically add the best POI expiration date
to the `users.poi_expiration` table from users DB.

=cut

BOM::User::Script::POIExpirationPopulator::run({noisy => 1});
