package BOM::Event::Actions::User;

use strict;
use warnings;

use BOM::Event::Services::Track;
use BOM::Platform::Client::Sanctions;
use BOM::User::Client;
use BOM::Platform::Context qw(request);
use List::Util qw(any);

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

    return BOM::Event::Services::Track::login(@args);
}

sub multiplier_hit_type {
    my @args = @_;

    return BOM::Event::Services::Track::multiplier_hit_type(@args);
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
    my @args   = @_;
    my $params = shift;

    # Apply sanctions on profile update
    if (any { exists $params->{properties}->{updated_fields}->{$_} } qw/first_name last_name date_of_birth/) {
        my $loginid = $params->{loginid};
        my $client  = BOM::User::Client->new({loginid => $loginid}) or die 'Could not instantiate client for login ID ' . $loginid;

        # Grab MT5 accounts and craft a summary
        my $mt5_logins = $client->user->mt5_logins_with_group;
        my @comments;

        push @comments, 'MT5 Accounts', map { sprintf(" - %s %s", $_, $mt5_logins->{$_}) } keys %{$mt5_logins} if scalar keys %{$mt5_logins};
        push @comments, '' if scalar keys %{$mt5_logins};
        push @comments, 'Triggered by profile update';

        BOM::Platform::Client::Sanctions->new({
                client => $client,
                brand  => request()->brand,
            }
        )->check((
            triggered_by => 'Triggered by profile update',
            comments     => join "\n",
            @comments,
        ));
    }

    return BOM::Event::Services::Track::profile_change(@args);
}

1;
