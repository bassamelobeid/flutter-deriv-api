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
    return BOM::Event::Services::Track::app_registered(@_);
}

=head2 app_updated

It is triggered for each B<app_updated> event emitted.

=cut

sub app_updated {
    return BOM::Event::Services::Track::app_updated(@_);
}

=head2 app_deleted

It is triggered for each B<app_updated> event emitted.

=cut

sub app_deleted {
    return BOM::Event::Services::Track::app_deleted(@_);
}

=head2 email_subscription

It is triggered when client B<email_subscription> event emitted.

=cut

sub email_subscription {
    return BOM::Event::Services::Track::email_subscription(@_);
}

1;
