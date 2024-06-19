package BOM::User::Client::AuthenticationDocuments::Config;

use strict;
use warnings;
use feature 'state';

=head1 NAME

BOM::User::Client::AuthenticationDocuments::Config - A standalone perl package that loads L<BOM::User::Client::AuthenticationDocuments> configuration and brings static access to this info.

=cut

use Path::Tiny;
use YAML::XS;
use Dir::Self;

=head2 categories

A helper function that loads the C<document_type_categories.yml> file carrying the documents configuration.

=cut

sub categories {
    my $path = Path::Tiny::path(__DIR__)->parent(5)->child('share', 'document_type_categories.yml');
    state $document_type_categories = YAML::XS::LoadFile($path);
    return $document_type_categories;
}

=head2 outdated_boundary

Computes the category expiration date based on its config. (static method)

It takes:

=over 4

=item * C<category> - the category being computed

=back

Returns a C<Date::Utility> or C<undef>.

=cut

sub outdated_boundary {
    my ($category) = @_;

    my $document_type_categories = BOM::User::Client::AuthenticationDocuments::Config::categories();

    if (my $category = $document_type_categories->{$category}) {
        if (my $ttl = $category->{time_to_live}) {
            return Date::Utility->new()->minus_time_interval($ttl);
        }
    }

    return undef;
}

=head2 poa_types

Returns an arrayref containing the POA types from the current configuration.

=cut

sub poa_types {
    return [keys BOM::User::Client::AuthenticationDocuments::Config::categories()->{POA}->{types}->%*];
}

=head2 poi_types

Returns an arrayref containing the POI types from the current configuration.

=cut

sub poi_types {
    return [keys BOM::User::Client::AuthenticationDocuments::Config::categories()->{POI}->{types}->%*];
}

1;
