package BOM::User::PhoneNumberVerification;

=head1 Description

This packages provides the logic and storage access for the Phone Number Verification feature.

=cut

use strict;
use warnings;
use Moo;
use BOM::Service;

use constant PNV_VERIFY_PREFIX     => 'PHONE::NUMBER::VERIFICATION::VERIFY::';
use constant PNV_NEXT_PREFIX       => 'PHONE::NUMBER::VERIFICATION::NEXT::';
use constant PNV_NEXT_EMAIL_PREFIX => 'PHONE::NUMBER::VERIFICATION::NEXT_EMAIL::';
use constant PNV_OTP_PREFIX        => 'PHONE::NUMBER::VERIFICATION::OTP::';
use constant TEN_MINUTES           => 600;                                           # 10 minutes in seconds
use constant ONE_MINUTE            => 60;                                            # 1 minute in seconds
use constant ONE_HOUR              => 3600;                                          # 1 hour in seconds
use constant SPAM_TOO_MUCH         => 3;

=head2 binary_user_id

The L<binary_user_id> value, a little convenience for operations that might require this reference.

=cut

has binary_user_id => (
    is       => 'ro',
    required => 1
);

=head2 user_service_context

The L<Hashref>, user service context

=cut

has user_service_context => (
    is       => 'ro',
    required => 1
);

=head2 verified 

Indicates the current status of the Phone Number Verification.

Either C<1> or C<0>.

=cut

has verified => (
    is       => 'ro',
    required => 1,
);

=head2 phone

The L<String>, user phone number

=cut

has phone => (
    is       => 'ro',
    required => 1,
);

=head2 email

The L<String>, user phone number

=cut

has email => (
    is       => 'ro',
    required => 1,
);

=head2 BUILDARGS

Compute the current status of the Phone Number Verification.

Returns Object or undef on failure.

=cut

# Constructor
around BUILDARGS => sub {
    my ($orig, $class, $user_id, $user_service_context) = @_;

    my $user_data = BOM::Service::user(
        context    => $user_service_context,
        command    => 'get_attributes',
        user_id    => $user_id,
        attributes => [qw(binary_user_id email phone phone_number_verified)],
    );
    return undef unless ($user_data->{status} eq 'ok');

    return $class->$orig(
        binary_user_id       => $user_data->{attributes}{binary_user_id},
        user_service_context => $user_service_context,
        phone                => $user_data->{attributes}{phone},
        email                => $user_data->{attributes}{email},
        verified             => $user_data->{attributes}{phone_number_verified});
};

=head2 clear_verify_attempts

Clears the next attempt of the OTP for the current L<BOM::User>.

=cut

sub clear_verify_attempts {
    my ($self) = @_;

    return undef if $self->verified;

    my $redis = BOM::Config::Redis::redis_events_write();

    $redis->del(PNV_VERIFY_PREFIX . $self->binary_user_id);
}

=head2 clear_attempts

Clears the next attempt of the current L<BOM::User>.

=cut

sub clear_attempts {
    my ($self) = @_;

    return undef if $self->verified;

    my $redis = BOM::Config::Redis::redis_events_write();

    $redis->del(PNV_NEXT_PREFIX . $self->binary_user_id);
}

=head2 email_blocked

Blocks the email atttempt if the redis TTL has not yet passed.

=cut

sub email_blocked {
    my ($self) = @_;

    my $redis = BOM::Config::Redis::redis_events_write();

    my $ttl = $redis->ttl(PNV_NEXT_EMAIL_PREFIX . $self->binary_user_id) // 0;

    return $ttl > 0;
}

=head2 next_email_attempt

Computes the next attempt for email verification of the current L<BOM::User>.

It returns a timestamp in seconds or C<undef> if there's no necessity for this timestamp.

=cut

sub next_email_attempt {
    my ($self) = @_;

    return undef if $self->verified;

    my $redis = BOM::Config::Redis::redis_events_write();

    my $ttl = $redis->ttl(PNV_NEXT_EMAIL_PREFIX . $self->binary_user_id) // 0;

    $ttl = 0 if $ttl < 0;

    return time + $ttl;
}

=head2 verify_blocked

Blocks the verification atttempts of the OTP due to too many attempts.

=cut

sub verify_blocked {
    my ($self) = @_;

    my $redis = BOM::Config::Redis::redis_events_write();

    my $attempts = $redis->get(PNV_VERIFY_PREFIX . $self->binary_user_id) // 0;

    return $attempts > SPAM_TOO_MUCH;
}

=head2 next_attempt

Computes the next attempt of the current L<BOM::User>.

It returns a timestamp in seconds or C<undef> if there's no necessity for this timestamp.

=cut

sub next_attempt {
    my ($self) = @_;

    return undef if $self->verified;

    my $redis = BOM::Config::Redis::redis_events_write();

    my $ttl = $redis->ttl(PNV_NEXT_PREFIX . $self->binary_user_id) // 0;

    $ttl = 0 if $ttl < 0;

    return time + $ttl;
}

=head2 next_verify_attempt

Computes the next verify attempt of the current L<BOM::User>.

It returns a timestamp in seconds or C<undef> if there's no necessity for this timestamp.

=cut

sub next_verify_attempt {
    my ($self) = @_;

    return undef if $self->verified;

    my $redis = BOM::Config::Redis::redis_events_write();

    my $attempts = $redis->get(PNV_VERIFY_PREFIX . $self->binary_user_id) // 0;

    my $ttl = $redis->ttl(PNV_VERIFY_PREFIX . $self->binary_user_id) // 0;

    $ttl = 0 unless $attempts > SPAM_TOO_MUCH;

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

    my $response = BOM::Service::user(
        context    => $self->user_service_context,
        command    => 'update_attributes',
        user_id    => $self->binary_user_id,
        attributes => {phone_number_verified => $verified},
    );
    die "Error updating phone number verification status: $response->{message}" if ($response->{status} ne 'ok');

    return undef;
}

=head2 generate_otp

Generates a new OTP and updates the redis state of the client verification.

Returns the new OTP as C<string>.

=cut

sub generate_otp {
    my ($self) = @_;

    # yes, the mocked OTP is just the user id
    my $otp = $self->binary_user_id;

    my $redis = BOM::Config::Redis::redis_events_write();

    # this OTP will be valid for ten minutes
    $redis->set(PNV_OTP_PREFIX . $self->binary_user_id, $otp, 'EX', TEN_MINUTES);

    return $otp;
}

=head2 increase_verify_attempts

Increases the number of the OTP verify attempts made by the current user.
Adjust the next attempt timestamp accordingly.

=cut

sub increase_verify_attempts {
    my ($self)   = @_;
    my $redis    = BOM::Config::Redis::redis_events_write();
    my $attempts = $redis->get(PNV_VERIFY_PREFIX . $self->binary_user_id) // 0;

    $attempts++;

    $redis->set(PNV_VERIFY_PREFIX . $self->binary_user_id, $attempts, 'EX', ONE_HOUR);

    return $attempts;
}

=head2 increase_attempts

Increases the number of attempts made by the current user.
Adjust the next attempt timestamp accordingly.

=cut

sub increase_attempts {
    my ($self)   = @_;
    my $redis    = BOM::Config::Redis::redis_events_write();
    my $attempts = $redis->get(PNV_NEXT_PREFIX . $self->binary_user_id) // 0;

    # the next attempt will be unlocked as soon as the OTP expires
    my $next_attempt = ONE_MINUTE;

    $next_attempt = ONE_HOUR unless $attempts < SPAM_TOO_MUCH;

    # unless the client spams too much
    $attempts++;

    $redis->set(PNV_NEXT_PREFIX . $self->binary_user_id, $attempts, 'EX', $next_attempt);

    return $attempts;
}

=head2 increase_email_attempts

Increases the number of email attempts made by the current user.
Adjust the next email attempt timestamp accordingly.

=cut

sub increase_email_attempts {
    my ($self)   = @_;
    my $redis    = BOM::Config::Redis::redis_events_write();
    my $attempts = $redis->get(PNV_NEXT_EMAIL_PREFIX . $self->binary_user_id) // 0;

    # the next attempt will be unlocked as soon as the OTP expires
    my $next_attempt = ONE_MINUTE;

    $next_attempt = ONE_HOUR unless $attempts < SPAM_TOO_MUCH;

    # unless the client spams too much
    $attempts++;

    $redis->set(PNV_NEXT_EMAIL_PREFIX . $self->binary_user_id, $attempts, 'EX', $next_attempt);

    return $attempts;
}

=head2 verify_otp

Attemps to verify the OTP for this user.

Returns a B<truthy> on success.

=cut

sub verify_otp {
    my ($self, $otp) = @_;

    return undef unless defined $otp;

    my $redis = BOM::Config::Redis::redis_events_write();

    my $stored_otp = $redis->get(PNV_OTP_PREFIX . $self->binary_user_id);

    return undef unless defined $stored_otp;

    return undef unless $otp eq $stored_otp;

    $redis->del(PNV_OTP_PREFIX . $self->binary_user_id);

    return 1;
}

1
