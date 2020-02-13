package BOM::Event::Actions::User;

use strict;
use warnings;

use BOM::Event::Services::Track;

=head1 NAME

BOM::Event::Actions::User

=head1 DESCRIPTION

Provides handlers for user-related events.

=cut

no indirect;

=head2 login

It is triggered for each B<login> event emitted.
It can be called with the following parameters:

=over

=item * C<loginid> - required. Login Id of the user.

=item * C<properties> - Free-form dictionary of event properties.

=back

=cut

sub login {
    my @args = @_;

    BOM::Event::Services::Track::login(@args)->retain;

    return 1;
}

=head2 profile_change

It is triggered for each B<changing in user profile> event emitted, delivering it to Segment.
It can be called with the following parameters:

=over

=item * C<loginid> - required. Login Id of the user.

=item * C<properties> - Free-form dictionary of event properties, including all fields that has been updated from Backoffice or set_settings API call.

=back

=cut

sub profile_change {
    my @args = @_;

    return BOM::Event::Services::Track::profile_change(@args);
}

1;
