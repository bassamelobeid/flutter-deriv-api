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

    my $args   = $params->{args};
    my $client = $params->{client};

    my $user = $client->user;
    my $pnv  = $user->pnv;

    return BOM::RPC::v3::Utility::create_error({
            code              => 'AlreadyVerified',
            message_to_client => localize('This account is already phone number verified')}) if $pnv->verified;

    my $next_attempt = $pnv->next_attempt;

    $pnv->increase_attempts();

    my $verification_code     = $args->{email_code};
    my $verification_response = BOM::RPC::v3::Utility::is_verification_token_valid($verification_code, $client->email, 'phone_number_verification');

    return $verification_response if $verification_response->{error};

    return BOM::RPC::v3::Utility::create_error({
            code              => 'NoAttemptsLeft',
            message_to_client => localize('Please wait for some time before requesting another OTP code')}) if time < $next_attempt;

    my $carrier = $args->{carrier};
    my $phone   = $client->phone;
    my $otp     = $pnv->generate_otp();

    $log->debugf("Sending OTP %s to %s, via %s, for user %d", $otp, $phone, $carrier, $user->id);

    $pnv->clear_verify_attempts();

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

    my $args   = $params->{args};
    my $client = $params->{client};

    my $user = $client->user;
    my $pnv  = $user->pnv;

    return BOM::RPC::v3::Utility::create_error({
            code              => 'AlreadyVerified',
            message_to_client => localize('This account is already phone number verified')}) if $pnv->verified;

    my $otp = $args->{otp} // '';

    $log->debugf("Verifying OTP %s, for user %d", $otp, $user->id);

    $pnv->increase_verify_attempts();

    my $verify_blocked = $pnv->verify_blocked;

    return BOM::RPC::v3::Utility::create_error({
            code              => 'NoAttemptsLeft',
            message_to_client => localize('Please wait for some time before sending the OTP')}) if $verify_blocked;

    return BOM::RPC::v3::Utility::create_error({
            code              => 'InvalidOTP',
            message_to_client => localize('The OTP is not valid')}) unless $pnv->verify_otp($otp);

    $pnv->update(1);

    $pnv->clear_verify_attempts();

    return 1;
};

1;
