package BOM::RPC::v3::PhoneNumberVerification;

=head1 NAME

BOM::RPC::v3::PhoneNumberVerification - a dummy package to serve as a mock of the final PNV services.

=head1 DESCRIPTION

Delivers a fixed, predictable behavior to the B<PNV> sequence.

=cut

use strict;
use warnings;
use Log::Any qw($log);
use BOM::RPC::Registry '-dsl';
use BOM::Platform::Context qw (localize);
use BOM::User::PhoneNumberVerification;
use BOM::Platform::Token;
use BOM::RPC::v3::Utility;
use DataDog::DogStatsd::Helper qw(stats_inc);
use BOM::Config::Runtime;
use List::Util qw(any);

requires_auth('trading', 'wallet');

=head2 phone_number_challenge

Generates and sends a mocked OTP to the current client's phone number, if available.

The mocked OTP is always the B<binary_user_id> of the client.

=over 4

=item * C<carrier> - Either I<whatsapp> or I<sms>.

=back

Returns 1 if the procedure was successful. 

=cut

rpc phone_number_challenge => sub {
    my $params  = shift;
    my $client  = $params->{client};
    my $args    = $params->{args};
    my $carrier = $args->{carrier};
    my @tags;
    my $broker    = $client->broker_code;
    my $residence = $client->residence;
    push @tags, "broker:$broker"       if defined $broker;
    push @tags, "residence:$residence" if defined $residence;
    push @tags, "carrier:$carrier"     if defined $carrier;

    stats_inc(
        'pnv.challenge.request',
        {
            tags => [@tags],
        });

    my $pnv = BOM::User::PhoneNumberVerification->new($params->{user_id}, $params->{user_service_context});

    return BOM::RPC::v3::Utility::client_error() unless defined $pnv;

    my $carriers_availability = $pnv->carriers_availability();
    my $is_enabled            = any { $_ } values $carriers_availability->%*;

    return error_with_metric('PhoneNumberVerificationSuspended', 'pnv.challenge.suspended', [@tags])
        unless $is_enabled;

    # Don't want to tell much about why is suspended, a generic error is fine
    if (defined $carrier) {
        if (defined $carriers_availability->{$carrier}) {
            return error_with_metric('PhoneNumberVerificationSuspended', sprintf('pnv.challenge.%s_suspended', $carrier), [@tags])
                if $pnv->is_suspended($carrier);

            return error_with_metric('PhoneNumberVerificationSuspended', sprintf('pnv.challenge.%s_depleted', $carrier), [@tags])
                if $pnv->is_depleted($carrier);

        } else {
            return error_with_metric('PhoneNumberVerificationSuspended', 'pnv.challenge.unsupported_carrier', [@tags]);
        }
    }

    return error_with_metric('VirtualNotAllowed', 'pnv.challenge.virtual_not_allowed', [@tags]) if $client->is_virtual;

    my $phone       = $pnv->phone // '';
    my $clear_phone = $pnv->clear_phone($phone);
    my $lang        = lc($pnv->preferred_language // 'en');

    return error_with_metric('InvalidPhone', 'pnv.challenge.invalid_phone', [@tags]) unless length($clear_phone);

    return error_with_metric('AlreadyVerified', 'pnv.challenge.already_verified', [@tags]) if $pnv->verified;

    return error_with_metric('PhoneNumberTaken', 'pnv.challenge.phone_number_taken', [@tags]) if $pnv->is_phone_taken($phone);

    my $next_attempt = $pnv->next_attempt;

    $pnv->increase_attempts();

    my $verification_code     = $args->{email_code};
    my $is_carrier_present    = defined $carrier ? 1 : 0;
    my $verification_response = BOM::RPC::v3::Utility::is_verification_token_valid($verification_code, $pnv->email, 'phone_number_verification', 1);

    if ($verification_response->{error}) {
        stats_inc('pnv.challenge.invalid_email_code', {tags => [@tags]});

        return $verification_response;
    }

    return error_with_metric('NoAttemptsLeft', 'pnv.challenge.no_attempts_left', [@tags]) if time < $next_attempt;

    if ($is_carrier_present) {
        if ($pnv->generate_otp($carrier, $phone, $lang)) {
            stats_inc(
                'pnv.challenge.success',
                {
                    tags => [@tags],
                });

            $log->debugf("Sending OTP to %s, via %s, for user %d", $phone, $carrier, $pnv->binary_user_id);
            $pnv->clear_verify_attempts();
        } else {
            $log->debugf("Failed to send OTP to %s, via %s, for user %d", $phone, $carrier, $pnv->binary_user_id);

            return error_with_metric('FailedToGenerateOTP', 'pnv.challenge.failed_otp', [@tags]);
        }
    } else {
        stats_inc(
            'pnv.challenge.verify_code_only',
            {
                tags => [@tags],
            });

        $log->debugf("Successfully verified email code for user %s for %s", $pnv->binary_user_id, $phone);
        $pnv->clear_attempts();
    }

    return 1;
};

=head2 phone_number_verify

Attempts to verify the client's phone number by checking the OTP challenge.

The mocked OTP is always the B<binary_user_id> of the client.

=over 4

=item * C<otp> - the OTP to check.

=back

Returns 1 if the procedure was successful. 

=cut

rpc phone_number_verify => sub {
    my $params = shift;
    my $client = $params->{client};
    my @tags;
    my $broker    = $client->broker_code;
    my $residence = $client->residence;
    push @tags, "broker:$broker"       if defined $broker;
    push @tags, "residence:$residence" if defined $residence;

    stats_inc(
        'pnv.verify.request',
        {
            tags => [@tags],
        });

    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->check_for_update;

    return error_with_metric('PhoneNumberVerificationSuspended', 'pnv.verify.suspended', [@tags])
        if $app_config->system->suspend->phone_number_verification;

    return error_with_metric('VirtualNotAllowed', 'pnv.verify.virtual_not_allowed', [@tags]) if $client->is_virtual;

    my $args = $params->{args};
    my $pnv  = BOM::User::PhoneNumberVerification->new($params->{user_id}, $params->{user_service_context});

    return BOM::RPC::v3::Utility::client_error() unless defined $pnv;

    my $phone       = $client->phone // '';
    my $clear_phone = $pnv->clear_phone($phone);

    return error_with_metric('InvalidPhone', 'pnv.verify.invalid_phone', [@tags]) unless length($clear_phone);

    return error_with_metric('AlreadyVerified', 'pnv.verify.already_verified', [@tags]) if $pnv->verified;

    return error_with_metric('PhoneNumberTaken', 'pnv.verify.phone_number_taken', [@tags]) if $pnv->is_phone_taken($phone);

    my $otp = $args->{otp} // '';

    $log->debugf("Verifying OTP %s to %s, for user %d", $otp, $phone, $pnv->binary_user_id);

    $pnv->increase_verify_attempts();

    my $verify_blocked = $pnv->verify_blocked;

    return error_with_metric('NoAttemptsLeft', 'pnv.verify.no_attempts_left', [@tags]) if $verify_blocked;

    return error_with_metric('InvalidOTP', 'pnv.verify.invalid_otp', [@tags]) unless $pnv->verify_otp($phone, $otp);

    # this is the most probably scenario if we ever hit an error here.
    return error_with_metric('PhoneNumberTaken', 'pnv.verify.phone_number_taken_maybe', [@tags]) unless $pnv->verify($phone);

    $pnv->clear_verify_attempts();

    stats_inc(
        'pnv.verify.success',
        {
            tags => [@tags],
        });

    return 1;
};

=head2 error_with_metric

This utility function returns an error along with some datadog metric transmission.

It takes the following params:

=over

=item * C<$error> - error to return as RPC response

=item * C<$metric> - the datadog metric to be send as C<string>

=item * C<$tags> - arrayref of tags to be sent along with the datadog metric

=back

It returns the RPC error.

=cut

sub error_with_metric {
    my ($error, $metric, $tags) = @_;

    stats_inc(
        $metric,
        {
            tags => $tags,
        });

    return BOM::RPC::v3::Utility::create_error_by_code($error);
}

1;
