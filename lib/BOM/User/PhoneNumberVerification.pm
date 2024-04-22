package BOM::User::PhoneNumberVerification;

=head1 Description

This packages provides the logic and storage access for the Phone Number Verification feature.

=cut

use strict;
use warnings;
use Moo;

use constant PNV_NEXT_PREFIX => 'PHONE::NUMBER::VERIFICATION::NEXT::';

=head2 user

The L<BOM::User> instance, a little convenience for operations that might require this reference.

=cut

has user => (
    is       => 'ro',
    required => 1,
    weak_ref => 1,
);

=head2 verified 

Indicates the current status of the Phone Number Verification.

Either C<1> or C<0>.

=cut

has verified => (
    is      => 'lazy',
    clearer => '_clear_verified',
);

=head2 _build_verified 

Compute the current status of the Phone Number Verification.

Returns C<1> or C<0>.

=cut

sub _build_verified {
    my ($self) = @_;

    return $self->user->phone_number_verified ? 1 : 0;
}

=head2 next_attempt

Computes the next attempt of the current L<BOM::User>.

It returns a timestamp in seconds or C<undef> if there's no necessity for this timestamp.

=cut

sub next_attempt {
    my ($self) = @_;

    return undef if $self->verified;

    my $redis = BOM::Config::Redis::redis_events_write();

    my $next = $redis->get(PNV_NEXT_PREFIX . $self->user->id) // 0;

    return $next;
}

=head2 update

Updates the phone verification status.

Takes the following argument:

=over 4

=item * C<verified> - a boolean value

=back

Returns C<undef>.

=cut

sub update {
    my ($self, $verified) = @_;

    $self->user->dbic(operation => 'write')->run(
        fixup => sub {
            $_->do('SELECT * FROM users.update_phone_number_verified(?::BIGINT, ?::BOOLEAN)', undef, $self->user->id, $verified ? 1 : 0);
        });

    return undef;
}

1
