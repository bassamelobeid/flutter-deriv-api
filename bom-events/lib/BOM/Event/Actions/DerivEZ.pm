package BOM::Event::Actions::DerivEZ;

use strict;
use warnings;

use BOM::User;
use Date::Utility;
use BOM::Event::Services::Track;
use Future::Utils          qw(fmap_void);
use BOM::Platform::Context qw(localize request);
use Path::Tiny;

=head2 derivez_inactive_notification

Sends emails to a user notifiying them about their inactive derivez accounts before they're closed.
Takes the following named parameters

=over 4

=item * C<email> - user's  email address

=item * C<name> - user's name

=item * C<accounts> - user's inactive derivez accounts grouped by days remaining to their closure, for example:

{
   7 => [{
             loginid => '1234',
             account_type => 'real gaming',
        },
        ...
    ],
    14 => [{
             loginid => '2345',
             account_type => 'demo financial',
        },
        ...
     ]
}

=back

=cut

sub derivez_inactive_notification {
    my ($args, $service_contexts) = @_;

    die "Missing service_contexts" unless $service_contexts;

    my $user    = eval { BOM::User->new(email => $args->{email}) } or die 'Invalid email address';
    my $loginid = eval { [$user->bom_loginids()]->[0] }            or die "User $args->{email} doesn't have any accounts";

    my $futures = fmap_void {
        BOM::Event::Services::Track::derivez_inactive_notification({
                loginid      => $loginid,
                email        => $args->{email},
                name         => $args->{name},
                accounts     => $args->{accounts}->{$_},
                closure_date => Date::Utility->new->plus_time_interval($_ . "d")->epoch,
            },
            $service_contexts
        );
    }
    foreach => [sort { $a <=> $b } keys $args->{accounts}->%*];

    return $futures->then(sub { Future->done(1) });
}

=head2 derivez_inactive_account_closed

Sends emails to a user notifiying them about their inactive derivez accounts before they're closed.
Takes the following named parameters

=over 4

=item * C<email> - user's  email address

=item * C<name> - user's name

=item * C<derivez_accounts> - a list of the archived derivez accounts with the same email address (binary user).

=back

=cut

sub derivez_inactive_account_closed {
    my ($args, $service_contexts) = @_;

    die "Missing service_contexts" unless $service_contexts;

    my $user    = eval { BOM::User->new(email => $args->{email}) } or die 'Invalid email address';
    my $loginid = eval { [$user->bom_loginids()]->[0] }            or die "User $args->{email} doesn't have any accounts";

    return BOM::Event::Services::Track::derivez_inactive_account_closed({
            loginid          => $loginid,
            name             => $args->{derivez_accounts}->[0]->{name},
            derivez_accounts => $args->{derivez_accounts},
            live_chat_url    => request->brand->live_chat_url({language => request->language})
        },
        $service_contexts
    );

}

1;
