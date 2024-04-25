package BOM::User::PhoneNumberVerification;

=head1 Description

This packages provides the logic and storage access for the Phone Number Verification feature.

=cut

use strict;
use warnings;
use Moo;

use constant PNV_NEXT_PREFIX => 'PHONE::NUMBER::VERIFICATION::NEXT::';
use constant PNV_OTP_PREFIX  => 'PHONE::NUMBER::VERIFICATION::OTP::';
use constant TEN_MINUTES     => 600;                                     # 10 minutes in seconds
use constant ONE_HOUR        => 3600;                                    # 1 hour in seconds
use constant SPAM_TOO_MUCH   => 5;

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

    my $ttl = $redis->ttl(PNV_NEXT_PREFIX . $self->user->id) // 0;

    $ttl = 0 if $ttl < 0;

    return time + $ttl;
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

=head2 generate_otp

Generates a new OTP and updates the redis state of the client verification.

Returns the new OTP as C<string>.

=cut

sub generate_otp {
    my ($self) = @_;

    # yes, the mocked OTP is just the user id
    my $otp = $self->user->id;

    my $redis = BOM::Config::Redis::redis_events_write();

    # this OTP will be valid for a whole minute
    $redis->set(PNV_OTP_PREFIX . $self->user->id, $otp, 'EX', TEN_MINUTES);

    return $otp;
}

=head2 increase_attempts

Increses the number of attempts made by the current user.
Adjust the next attempt timestamp accordingly.

=cut

sub increase_attempts {
    my ($self)   = @_;
    my $redis    = BOM::Config::Redis::redis_events_write();
    my $attempts = $redis->get(PNV_NEXT_PREFIX . $self->user->id) // 0;

    # the next attempt will be unlocked as soon as the OTP expires
    my $next_attempt = TEN_MINUTES;

    # unless the client spams too much
    $next_attempt = ONE_HOUR unless $attempts < SPAM_TOO_MUCH;

    $attempts++;

    $redis->set(PNV_NEXT_PREFIX . $self->user->id, $attempts, 'EX', $next_attempt);

    return $attempts;
}

1
