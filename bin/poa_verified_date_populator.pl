#!/etc/rmg/bin/perl

package main;
use strict;
use warnings;

use BOM::User::Script::POAVerifiedDatePopulator;

=head1 NAME

poa_verified_date_populator.pl

=head1 DESCRIPTION

This is an SRP after script that extracts the verified date of POA documents from `audit.client_authentication_document
and adds it to the `betonmarkets.client_authentication_document` table from client DB.

=cut

BOM::User::Script::POAVerifiedDatePopulator::run({noisy => 1});
