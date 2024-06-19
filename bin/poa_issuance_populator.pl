#!/etc/rmg/bin/perl

package main;
use strict;
use warnings;

use BOM::User::Script::POAIssuancePopulator;

=head1 NAME

poa_issuance_populator.pl

=head1 DESCRIPTION

This is a SRP after script that automatically add the best POA issue date 
to the `users.poa_issuance` table from users DB.

=cut

BOM::User::Script::POAIssuancePopulator::run({noisy => 1});
