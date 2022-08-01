package BOM::RPC::v3::IdentityVerification;

use strict;
use warnings;

use BOM::Platform::Context qw(localize);
use BOM::Platform::Event::Emitter;
use BOM::Platform::Utility;
use BOM::RPC::Registry '-dsl';
use BOM::User::IdentityVerification;

use Brands::Countries;

=head2 identity_verification_document_add

Submits provided document information for authenticated user in order for IDV later uses.

Looking for the following arguments:

=over 4

=item * C<issuing_country> - The 2-letter country code which document issued in.

=item * C<document_type> - The type of the document e.g. national_id, passport, etc.

=item * C<document_number> - An alpha-numeric value as document identification number

=back

Returns 1 if the procedure was successful. 

=cut

requires_auth('trading', 'wallet');

rpc identity_verification_document_add => sub {
    my $params = shift;

    my $args   = $params->{args};
    my $client = $params->{client};

    my $issuing_country = lc($args->{issuing_country} // '');
    my $document_type   = lc($args->{document_type}   // '');
    my $document_number = $args->{document_number} // '';

    # If issuing_country is not provided, then we will default to client's citizen or residence
    $issuing_country = $client->citizen || $client->residence unless $issuing_country;

    return BOM::RPC::v3::Utility::create_error({
            code              => 'NoAuthNeeded',
            message_to_client => localize("You don't need to authenticate your account at this time.")}
    ) unless $client->status->allow_document_upload;

    return BOM::RPC::v3::Utility::create_error({
            code              => 'NoSubmissionLeft',
            message_to_client => localize("You've reached the maximum number of attempts for verifying your proof of identity with this method.")}
    ) if BOM::User::IdentityVerification::submissions_left($client) == 0;

    my $countries = Brands::Countries->new;
    return BOM::RPC::v3::Utility::create_error({
            code              => 'NotSupportedCountry',
            message_to_client => localize("The country you selected isn't supported.")}) unless $countries->is_idv_supported($issuing_country);

    my $configs = $countries->get_idv_config($issuing_country);
    return BOM::RPC::v3::Utility::create_error({
            code              => 'InvalidDocumentType',
            message_to_client => localize("The document type you entered isn't supported for the country you selected.")}
    ) unless exists $configs->{document_types}->{$document_type};

    return BOM::RPC::v3::Utility::create_error({
            code              => 'IdentityVerificationDisabled',
            message_to_client => localize("This verification method is currently unavailable.")})
        unless BOM::Platform::Utility::has_idv(
        country  => $issuing_country,
        provider => $configs->{provider});

    my $regex = $configs->{document_types}->{$document_type}->{format};

    return BOM::RPC::v3::Utility::create_error({
            code              => 'InvalidDocumentNumber',
            message_to_client => localize("It looks like the document number you entered is invalid. Please check and try again.")}
    ) if $document_number !~ m/$regex/;

    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->binary_user_id);

    return BOM::RPC::v3::Utility::create_error({
            code              => 'AlreadyAgeVerified',
            message_to_client => localize("Your age already been verified."),
        }) if $client->status->age_verification;

    return BOM::RPC::v3::Utility::create_error({
            code              => 'IdentityVerificationDisallowed',
            message_to_client => localize("This method of verification is not allowed. Please try another method.")}
    ) if BOM::RPC::v3::Utility::is_idv_disallowed($client);

    $idv_model->add_document({
        issuing_country => $issuing_country,
        number          => $document_number,
        type            => $document_type
    });

    BOM::Platform::Event::Emitter::emit('identity_verification_requested', {loginid => $client->loginid});

    return 1;
};

1;
