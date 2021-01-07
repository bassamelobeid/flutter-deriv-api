
=head1 NAME

BOM::Platform::Locale

=head1 DESCRIPTION

Package containing functions to support locality-related actions.

=cut

package BOM::Platform::Locale;

use strict;
use warnings;
use feature "state";
use utf8;    # to support source-embedded country name strings in this module
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

    if ($country_code eq 'JP') {
        my %list = (
            '01' => '北海道',
            '02' => '青森県',
            '03' => '岩手県',
            '04' => '宮城県',
            '05' => '秋田県',
            '06' => '山形県',
            '07' => '福島県',
            '08' => '茨城県',
            '09' => '栃木県',
            '10' => '群馬県',
            '11' => '埼玉県',
            '12' => '千葉県',
            '13' => '東京都',
            '14' => '神奈川県',
            '15' => '新潟県',
            '16' => '富山県',
            '17' => '石川県',
            '18' => '福井県',
            '19' => '山梨県',
            '20' => '長野県',
            '21' => '岐阜県',
            '22' => '静岡県',
            '23' => '愛知県',
            '24' => '三重県',
            '25' => '滋賀県',
            '26' => '京都府',
            '27' => '大阪府',
            '28' => '兵庫県',
            '29' => '奈良県',
            '30' => '和歌山県',
            '31' => '鳥取県',
            '32' => '島根県',
            '33' => '岡山県',
            '34' => '広島県',
            '35' => '山口県',
            '36' => '徳島県',
            '37' => '香川県',
            '38' => '愛媛県',
            '39' => '高知県',
            '40' => '福岡県',
            '41' => '佐賀県',
            '42' => '長崎県',
            '43' => '熊本県',
            '44' => '大分県',
            '45' => '宮崎県',
            '46' => '鹿児島県',
            '47' => '沖縄県',
        );

        push @options, map { {value => $_, text => $list{$_}} }
            sort (keys %list);
        return \@options;
    }

    my $country = Locale::SubCountry->new($country_code);
    if ($country and $country->has_sub_countries) {
        my %name_map = $country->full_name_code_hash;
        push @options, map { {value => $name_map{$_}, text => $_} }
            sort $country->all_full_names;
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

1;
