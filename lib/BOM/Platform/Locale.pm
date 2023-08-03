
=head1 NAME

BOM::Platform::Locale

=head1 DESCRIPTION

Package containing functions to support locality-related actions.

=cut

package BOM::Platform::Locale;

use strict;
use warnings;
use feature "state";
use List::Util qw /first/;

use utf8;             # to support source-embedded country name strings in this module
use JSON::MaybeXS;    #Locale::SubCountry using JSON::XS, so we should use JSON::MaybeXS before that
use Locale::SubCountry;

use BOM::Config::Runtime;
use BOM::Platform::Context qw(request localize);

sub translate_salutation {
    my $provided = shift;

    my %translated_titles = (
        MS   => localize('Ms'),
        MISS => localize('Miss'),
        MRS  => localize('Mrs'),
        MR   => localize('Mr'),
    );

    return $translated_titles{uc $provided} || $provided;
}

=head2 get_state_option

    $list_of_states = get_state_option($country_code)

Given a 2-letter country code, returns a list of states for that country.

Takes a scalar containing a 2-letter country code.

Returns an arrayref of hashes, alphabetically sorted by the states in that country. 

Each hash contains the following keys:

=over 4

=item * text (Name of state)

=item * value (Index of state when sorted alphabetically)

=back

=cut

sub get_state_option {
    my $country_code = shift or return;

    $country_code = uc $country_code;
    state %codes;
    unless (%codes) {
        %codes = Locale::SubCountry::World->code_full_name_hash;
    }
    return unless $codes{$country_code};

    my @options = ({
            value => '',
            text  => localize('Please select')});

    my $country = Locale::SubCountry->new($country_code);
    if ($country and $country->has_sub_countries) {
        my %name_map = $country->full_name_code_hash;
        push @options, map { {value => $name_map{$_}, text => $_} }
            sort $country->all_full_names;
    }

    # to avoid issues let's assume a stateless country has a default self-titled state

    if (scalar @options == 1) {
        my $countries_instance = request()->brand->countries_instance;
        my $countries          = $countries_instance->countries;
        my $country_name       = $countries->localized_code2country($country_code, request()->language);

        push @options,
            {
            value => '00',
            text  => $country_name,
            };
    }

    # Filter out some Netherlands territories
    @options = grep { $_->{value} !~ /\bSX|AW|BQ1|BQ2|BQ3|CW\b/ } @options if $country_code eq 'NL';
    # Filter out some France territories
    @options = grep { $_->{value} !~ /\bBL|WF|PF|PM\b/ } @options if $country_code eq 'FR';

    return \@options;
}

=head2 get_state_by_id

    $state_name = get_state_by_id($id, $residence)

Lookup full state name by state id and residence.

Returns undef when state is not found.

Takes two scalars:

=over 4

=item * id (ID of a state, for example, 'BA' for Bali)

=item * residence (2-letter country code, for example, 'id' for Indonesia)

=back

Returns the full name of the state if found (e.g. Bali), or undef otherwise.

Usage: get_state_by_id('BA', 'id') => Bali

=cut

sub get_state_by_id {
    my $id           = shift;
    my $residence    = shift;
    my ($state_name) = sort map { $_->{text} } grep { $_->{value} eq $id } @{get_state_option($residence) || []};

    return $state_name;
}

=head2 validate_state

    validate_state($state, $residence)

Lookup the state hashref by the state's code or name, and residence.

Returns undef when state is not found.

Takes two scalars:

=over 4

=item * state (code or name of a state, for example, 'BA' or Bali)

=item * residence (2-letter country code, for example, 'id' for Indonesia)

=back

Returns the hash value of the state if found (e.g. { value => 'BA', text => 'Bali' }), or undef otherwise.

Usage: validate_state('BA', 'id') => { value => 'BA', text => 'Bali' }
       validate_state('Bury', 'id') => undef

=cut

sub validate_state {
    my $state     = shift;
    my $residence = shift;
    my $match     = first { lc $_->{value} eq lc $state or lc $_->{text} eq lc $state } @{get_state_option($residence) || []};

    return $match;
}

1;
