package BOM::Event::Actions::App;

use strict;
use warnings;

use BOM::Event::Services::Track;

=head1 NAME

BOM::Event::Actions::App

=head1 DESCRIPTION

Provides handlers for app-related events.

=cut

no indirect;

=head2 app_registered

It is triggered for each B<app_registered> event emitted.

=cut

sub app_registered {
    my @args = @_;

    return BOM::Event::Services::Track::app_registered(@args);
}

=head2 app_updated

It is triggered for each B<app_updated> event emitted.

=cut

sub app_updated {
    my @args = @_;

    return BOM::Event::Services::Track::app_updated(@args);
}

=head2 app_deleted

It is triggered for each B<app_updated> event emitted.

=cut

sub app_deleted {
    my @args = @_;

    return BOM::Event::Services::Track::app_deleted(@args);
}

1;
