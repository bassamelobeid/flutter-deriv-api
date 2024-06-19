#!/etc/rmg/bin/perl

package main;
use strict;
use warnings;

use BOM::User::Script::IDVPhotoIdUpdater;

=head1 NAME

idv_photo_id_updater.pl

=head1 DESCRIPTION

This is an SRP after script that automatically add the authentication method IDV_PHOTO.

For more details look at L<BOM::User::Script::IDVPhotoIdUpdater>.

=cut

BOM::User::Script::IDVPhotoIdUpdater::run({noisy => 1});
