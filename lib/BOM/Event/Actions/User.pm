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

1;
