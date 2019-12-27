package BOM::Config::Onfido;

=head1 NAME

BOM::Config::Onfido

=head1 DESCRIPTION

A repository that consists data related to Onfido.

=cut

use strict;
use warnings;

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

Returns the supported_documents_list for the country

=cut

sub supported_documents_for_country {
    my $country_code = shift;

    $country_code = uc(country_code2code($country_code, 'alpha-2', 'alpha-3') // '');
    return [] unless $country_code;

    my %country_details = _get_country_details();

    return $country_details{$country_code}->{doc_types_list} // [];
}

=head2 is_country_supported

Returns 1 if country is supported and 0 if it is not supported

=cut

sub is_country_supported {
    my $country_code = shift;

    $country_code = uc(country_code2code($country_code, 'alpha-2', 'alpha-3') // '');

    my %country_details = _get_country_details();

    return $country_details{$country_code}->{doc_types_list} ? 1 : 0;
}

=head2 _get_country_details

Changes the format into hash

=cut

sub _get_country_details {

    return map { $_->{country_code} => $_ } @{supported_documents_list()};
}

1;
