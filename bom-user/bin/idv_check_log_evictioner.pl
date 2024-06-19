#!/etc/rmg/bin/perl

package main;
use strict;
use warnings;

use BOM::User::Script::IDVCheckLogEvictioner;

=head1 NAME

idv_photo_id_updater.pl

=head1 DESCRIPTION

This is an cron script that automatically evicts older `idv.document_check_log` partitions.

=cut

BOM::User::Script::IDVCheckLogEvictioner::run();
