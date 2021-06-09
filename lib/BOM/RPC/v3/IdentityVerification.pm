package BOM::RPC::v3::IdentityVerification;

use strict;
use warnings;
use Brands::Countries;
use BOM::RPC::Registry '-dsl';
use BOM::Platform::Context qw(localize);

=head2 identity_verification_document_add

sub to get identification-document info from user and save it in the databse, in order for later use in IDV (identity verification)

Takes the following arguments as named parameters

=over 4

=item * C<issuing_country> - the country which document issued in

=item * C<document_type> - type of the document, e.g. national_id, passport, etc.

=item * C<document_number> - An alpha-numeric value as document identification number

=back

Returns 1 if the procedure was successful. 

=cut

rpc identity_verification_document_add => sub {
    my $params = shift;

    my $args            = $params->{args};
    my $issuing_country = $args->{issuing_country};
    my $document_type   = $args->{document_type};
    my $document_number = $args->{document_number};

    my $countries = Brands::Countries->new;

    unless ($countries->is_idv_supported($issuing_country)) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'NotSupportedCountry',
                message_to_client => localize('Country code is not supported.')});
    }
    my $configs = $countries->get_idv_config($issuing_country);

    unless (exists($configs->{document_types}->{$document_type})) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidDocumentType',
                message_to_client => localize('Invalid document type')});
    }

    my $regex = $configs->{document_types}->{$document_type}->{format};
    if ($document_number !~ m/$regex/) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidDocumentNumber',
                message_to_client => localize('It looks like the document number you entered is invalid. Please check and try again.')});
    }

    # TODO save data to database

    return 1;
};

1;
