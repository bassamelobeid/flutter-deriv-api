package BOM::User::PhoneNumberVerification;

=head1 Description

This packages provides the logic and storage access for the Phone Number Verification feature.

=cut

use strict;
use warnings;
use Moo;
use Syntax::Keyword::Try;
use HTTP::Tiny;
use Log::Any        qw($log);
use JSON::MaybeUTF8 qw(decode_json_utf8);
use BOM::Config::Services;
use BOM::Service;
use BOM::User;

use constant PNV_VERIFY_PREFIX     => 'PHONE::NUMBER::VERIFICATION::VERIFY::';
use constant PNV_NEXT_PREFIX       => 'PHONE::NUMBER::VERIFICATION::NEXT::';
use constant PNV_NEXT_EMAIL_PREFIX => 'PHONE::NUMBER::VERIFICATION::NEXT_EMAIL::';
use constant PNV_OTP_PREFIX        => 'PHONE::NUMBER::VERIFICATION::OTP::';
use constant TEN_MINUTES           => 600;                                           # 10 minutes in seconds
use constant ONE_MINUTE            => 60;                                            # 1 minute in seconds
use constant ONE_HOUR              => 3600;                                          # 1 hour in seconds
use constant SPAM_TOO_MUCH         => 3;                                             # back to back failures before locking down
use constant HTTP_TIMEOUT          => 20;                                            # 20 seconds

# Constants used at the RPC verify email endpoint
use constant EMAIL_OTP_ALPHABET   => [0 .. 9];
use constant EMAIL_OTP_LENGTH     => 6;
use constant EMAIL_OTP_EXPIRES_IN => TEN_MINUTES;

=head2 http

Returns the current L<HTTP::Tiny> instance or creates a new one if neeeded.

=cut

has http => (
    is      => 'lazy',
    clearer => '_clear_http',
);

=head2 _build_http

Create the C<HTTP::Tiny> instance.

=cut

sub _build_http {
    return HTTP::Tiny->new(timeout => HTTP_TIMEOUT);
}

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

=head2 preferred_language

The L<String>, user preferred language

=cut

has preferred_language => (
    is       => 'ro',
    required => 1,
);

=head2 email

The L<String>, user email

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
        attributes => [qw(binary_user_id email phone phone_number_verified preferred_language)],
    );

    return undef unless ($user_data->{status} eq 'ok');

    return $class->$orig(
        binary_user_id       => $user_data->{attributes}{binary_user_id},
        user_service_context => $user_service_context,
        phone                => $user_data->{attributes}{phone},
        email                => $user_data->{attributes}{email},
        verified             => $user_data->{attributes}{phone_number_verified},
        preferred_language   => $user_data->{attributes}{preferred_language},
    );
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

Hits the PNV golang service /pnv/challenge/{carrier}/{phone}/{lang}

It takes:

=over 4

=item C<$carrier> - the carrier used to transport the OTP

=item C<$phone> - the phone number to send the OTP

=item C<$lang> - preferred language of the OTP message

=back

Returns a C<1> on a successful request, C<0> otherwise.

=cut

sub generate_otp {
    my ($self, $carrier, $phone, $lang) = @_;

    my $config = BOM::Config::Services->config('phone_number_verification');
    my $url    = sprintf("http://%s:%d/pnv/challenge/%s/%s/%s", $config->{host}, $config->{port}, $carrier, $phone, $lang);

    # Hit the PNV golang service
    try {
        my $resp = $self->http->get($url);

        $resp->{content} = decode_json_utf8($resp->{content} || '{}');

        return 1 if $resp->{content}->{success};
    } catch ($e) {
        $log->errorf("Unable to generate phone number for user %d: %s", $self->binary_user_id, $e);
    }

    return 0;
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

=head2 is_phone_taken

Takes the following:

=over 4

=item * C<$phone> - the phone number to check

=back

This function returns a boolean that indicates:

=over 4

=item * B<truthy> - the phone number has been taken by another user, not allowed to verify

=item * B<falsey> - can be taken by this user/the user is the actual owner

=back

=cut

sub is_phone_taken {
    my ($self, $phone) = @_;

    my $clear_phone = $self->clear_phone($phone);

    my ($result) = BOM::User->dbic->run(
        fixup => sub {
            $_->selectrow_array('SELECT * FROM users.is_phone_number_taken(?::BIGINT, ?::TEXT)', undef, $self->binary_user_id, $clear_phone);
        });

    return $result;
}

=head2 verify

Set the verification status to TRUE and also locks the phone number so nobody else can claim it.

Takes the following:

=over 4

=item * C<$phone> - the phone number to check

=back

Returns C<truthy> when the operation is successful.

=cut

sub verify {
    my ($self, $phone) = @_;

    my $clear_phone = $self->clear_phone($phone);

    try {
        BOM::User->dbic(operation => 'write')->run(
            fixup => sub {
                $_->do('SELECT * FROM users.phone_number_verify(?::BIGINT, ?::TEXT)', undef, $self->binary_user_id, $clear_phone);
            });
    } catch ($e) {
        my $error = split('|', $e // '');    # avoid leaking the phone number

        $log->errorf("Unable to verify phone number for user %d: %s", $self->binary_user_id, $error);

        return undef;
    }

    return 1;
}

=head2 release

Set the verification status to FALSE and also unlocks the phone number so other users can claim it.

Returns C<truthy> when the operation is successful.

=cut

sub release {
    my ($self) = @_;

    try {
        BOM::User->dbic(operation => 'write')->run(
            fixup => sub {
                $_->do('SELECT * FROM users.phone_number_release(?::BIGINT)', undef, $self->binary_user_id);
            });
    } catch ($e) {
        my $error = split('|', $e // '');    # avoid leaking the phone number

        $log->errorf("Unable to release phone number for user %d: %s", $self->binary_user_id, $error);

        return undef;
    }
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

Hits the PNV golang service /pnv/verify/{phone}/{otp}

It takes:

=over 4

=item C<$phone> - the phone number to check

=item C<$otp> - the OTP to match

=back

Returns a C<1> on a successful request, C<0> otherwise.

=cut

sub verify_otp {
    my ($self, $phone, $otp) = @_;

    my $config = BOM::Config::Services->config('phone_number_verification');
    my $url    = sprintf("http://%s:%d/pnv/verify/%s/%s", $config->{host}, $config->{port}, $phone, $otp);

    # Hit the PNV golang service
    try {
        my $resp = $self->http->get($url);

        $resp->{content} = decode_json_utf8($resp->{content} || '{}');

        return 1 if $resp->{content}->{success};
    } catch ($e) {
        $log->errorf("Unable to verify phone number for user %d: %s", $self->binary_user_id, $e);
    }

    return 0;
}

=head2 clear_phone

Removes all non digits from the incoming phone.

Takes the following argument:

=over 4

=item * C<$phone> - the phone to be cleared

=back

Returns the only digits version of the phone number

=cut

sub clear_phone {
    my (undef, $phone) = @_;

    my $dirty_phone = $phone;

    $dirty_phone =~ s/\D//g;

    return $dirty_phone;    # no longer dirty hehe
}

1
