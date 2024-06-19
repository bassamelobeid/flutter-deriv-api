#!/etc/rmg/bin/perl

package main;
use strict;
use warnings;

use BOM::User::Script::POIOwnershipPopulator;

=head1 NAME

poi_ownership_populator.pl

=head1 DESCRIPTION

This is a SRP after script that automatically adds ownership to all the documents that have:

- document_type
- issuing_country
- document_id (these are the document numbers)

=cut

BOM::User::Script::POIOwnershipPopulator::run({noisy => 1});
