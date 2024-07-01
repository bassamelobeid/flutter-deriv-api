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
    my $params = shift;
    my $client = $params->{client};

    return BOM::RPC::v3::Utility::create_error_by_code('VirtualNotAllowed') if $client->is_virtual;

    my $args = $params->{args};
    my $pnv  = BOM::User::PhoneNumberVerification->new($params->{user_id}, $params->{user_service_context});

    return BOM::RPC::v3::Utility::client_error() unless defined $pnv;

    my $carrier     = $args->{carrier};
    my $phone       = $pnv->phone // '';
    my $clear_phone = $pnv->clear_phone($phone);
    my $lang        = lc($pnv->preferred_language // 'en');

    return BOM::RPC::v3::Utility::create_error_by_code('InvalidPhone') unless length($clear_phone);

    return BOM::RPC::v3::Utility::create_error({
            code              => 'AlreadyVerified',
            message_to_client => localize('This account is already phone number verified')}) if $pnv->verified;

    return BOM::RPC::v3::Utility::create_error_by_code('PhoneNumberTaken') if $pnv->is_phone_taken($phone);

    my $next_attempt = $pnv->next_attempt;

    $pnv->increase_attempts();

    my $verification_code     = $args->{email_code};
    my $is_carrier_present    = defined $carrier ? 1 : 0;
    my $verification_response = BOM::RPC::v3::Utility::is_verification_token_valid($verification_code, $pnv->email, 'phone_number_verification', 1);

    return $verification_response if $verification_response->{error};

    return BOM::RPC::v3::Utility::create_error({
            code              => 'NoAttemptsLeft',
            message_to_client => localize('Please wait for some time before requesting another OTP code')}) if time < $next_attempt;

    if ($is_carrier_present) {
        if ($pnv->generate_otp($carrier, $phone, $lang)) {
            $log->debugf("Sending OTP to %s, via %s, for user %d", $phone, $carrier, $pnv->binary_user_id);
            $pnv->clear_verify_attempts();
        } else {
            $log->debugf("Failed to send OTP to %s, via %s, for user %d", $phone, $carrier, $pnv->binary_user_id);

            return BOM::RPC::v3::Utility::create_error({
                    code              => 'FailedToGenerateOTP',
                    message_to_client => localize('Could not generate OTP, please try again in a few minutes')});
        }
    } else {
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

    return BOM::RPC::v3::Utility::create_error_by_code('VirtualNotAllowed') if $client->is_virtual;

    my $args = $params->{args};
    my $pnv  = BOM::User::PhoneNumberVerification->new($params->{user_id}, $params->{user_service_context});

    return BOM::RPC::v3::Utility::client_error() unless defined $pnv;

    my $phone       = $client->phone // '';
    my $clear_phone = $pnv->clear_phone($phone);

    return BOM::RPC::v3::Utility::create_error_by_code('InvalidPhone') unless length($clear_phone);

    return BOM::RPC::v3::Utility::create_error({
            code              => 'AlreadyVerified',
            message_to_client => localize('This account is already phone number verified')}) if $pnv->verified;

    return BOM::RPC::v3::Utility::create_error_by_code('PhoneNumberTaken') if $pnv->is_phone_taken($phone);

    my $otp = $args->{otp} // '';

    $log->debugf("Verifying OTP %s to %s, for user %d", $otp, $phone, $pnv->binary_user_id);

    $pnv->increase_verify_attempts();

    my $verify_blocked = $pnv->verify_blocked;

    return BOM::RPC::v3::Utility::create_error({
            code              => 'NoAttemptsLeft',
            message_to_client => localize('Please wait for some time before sending the OTP')}) if $verify_blocked;

    return BOM::RPC::v3::Utility::create_error({
            code              => 'InvalidOTP',
            message_to_client => localize('The OTP is not valid')}) unless $pnv->verify_otp($phone, $otp);

    # this is the most probably scenario if we ever hit an error here.
    return BOM::RPC::v3::Utility::create_error_by_code('PhoneNumberTaken') unless $pnv->verify($phone);

    $pnv->clear_verify_attempts();

    return 1;
};

1;
