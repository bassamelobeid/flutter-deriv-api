package BOM::Config::Onfido;

use strict;
use warnings;
use feature "state";

=head1 NAME

C<BOM::Config::Onfido>

=head1 DESCRIPTION

A module that consists methods to get config data related to Onfido.

=cut

use JSON::MaybeUTF8 qw(:v1);
use Locale::Codes::Country qw(country_code2code);

use BOM::Config;

=head2 supported_documents_list

Returns an array of hashes of supported_documents for each country

=cut

sub supported_documents_list {
    my $supported_documents = BOM::Config::onfido_supported_documents();
    return $supported_documents;
}

=head2 supported_documents_for_country

Takes the following argument(s) as parameters:

=over 4

=item * C<$country_code> - The ISO code of the country

=back

Example:

    my $supported_docs_my = BOM::Config::Onfido::support_documents_for_country('my');

Returns the supported_documents_list for the country.

=cut

sub supported_documents_for_country {
    my $country_code = shift;

    $country_code = uc(country_code2code($country_code, 'alpha-2', 'alpha-3') // '');
    return [] unless $country_code;

    my $country_details = _get_country_details();

    return $country_details->{$country_code}->{doc_types_list} // [];
}

=head2 is_country_supported

Returns 1 if country is supported and 0 if it is not supported

=cut

sub is_country_supported {
    my $country_code = shift;

    return 0 if is_disabled_country($country_code);

    $country_code = uc(country_code2code($country_code, 'alpha-2', 'alpha-3') // '');

    my $country_details = _get_country_details();

    return $country_details->{$country_code}->{doc_types_list} ? 1 : 0;
}

=head2 is_disabled_country

Returns 1 if the country is disabled, 0 otherwise.

=cut

sub is_disabled_country {
    my $country_code = shift;

    $country_code = uc(country_code2code($country_code, 'alpha-2', 'alpha-3') // '') if (length($country_code) == 2);

    my $country_details = _get_country_details();

    return $country_details->{$country_code}->{disabled} ? 1 : 0;
}

=head2 _get_country_details

Changes the format into hash

=cut

sub _get_country_details {
    state $country_details = +{map { $_->{country_code} => $_ } @{supported_documents_list()}};
    return $country_details;
}

1;
