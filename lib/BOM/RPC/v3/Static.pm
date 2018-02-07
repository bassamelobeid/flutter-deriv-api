
=head1 NAME

BOM::RPC::v3::Static

=head1 DESCRIPTION

This is a package containing various utility functions for bom-rpc.

=cut

package BOM::RPC::v3::Static;

use strict;
use warnings;

no indirect;

use List::Util qw( min max );
use List::UtilsBy qw(nsort_by);
use Time::HiRes ();

use Brands;
use LandingCompany::Registry;
use Format::Util::Numbers qw/financialrounding/;
use Postgres::FeedDB::CurrencyConverter qw(in_USD amount_from_to_currency);
use DataDog::DogStatsd::Helper qw(stats_timing stats_gauge);
use Unicode::UTF8 qw(decode_utf8);
use JSON::MaybeXS;

use BOM::RPC::Registry '-dsl';

use BOM::Platform::RedisReplicated;
use BOM::Platform::Runtime;
use BOM::Platform::Locale;
use BOM::Platform::Config;
use BOM::Platform::Context qw (request);
use BOM::Database::ClientDB;
use BOM::RPC::v3::Utility;

=head2 residence_list

    $residence_list = residence_list()

Does not take in any parameters.

Returns an array of hashes, sorted by country name. Each contains the following:

=over 4

=item * text (country name)

=item * value (2-letter country code)

=item * phone_idd (International Direct Dialing code)

=item * disabled (optional, only appears for countries where clients cannot open accounts)

=back

=cut

rpc residence_list => sub {
    my $residence_countries_list;

    my $countries_instance = Brands->new(name => request()->brand)->countries_instance;
    my $countries = $countries_instance->countries;
    foreach my $country_selection (
        sort { $a->{translated_name} cmp $b->{translated_name} }
        map { +{code => $_, translated_name => $countries->localized_code2country($_, request()->language)} } $countries->all_country_codes
        )
    {
        my $country_code = $country_selection->{code};
        next if $country_code eq '';
        my $country_name = $country_selection->{translated_name};
        my $phone_idd    = $countries->idd_from_code($country_code);

        my $option = {
            value => $country_code,
            text  => $country_name,
            $phone_idd ? (phone_idd => $phone_idd) : ()};

        # to be removed later - JP
        if ($countries_instance->restricted_country($country_code) or $country_code eq 'jp') {
            $option->{disabled} = 'DISABLED';
        } elsif (request()->country_code eq $country_code) {
            $option->{selected} = 'selected';
        }
        push @$residence_countries_list, $option;
    }

    return $residence_countries_list;
};

=head2 states_list

    $list_of_states = states_list({states_list => $states})

Given a 2-letter country code, returns the list of states in a given country.

Takes a single C<$params> hashref containing the following keys:

=over 4

=item * args which contains the following keys:

=over 4

=item * states_list (a 2-letter country code)

=back

=back

Returns an array of hashes, alphabetically sorted by the states in that country. 

Each hash contains the following keys:

=over 4

=item * text (Name of state)

=item * value (Index of state when sorted alphabetically)

=back

=cut

rpc states_list => sub {
    my $params = shift;

    my $states = BOM::Platform::Locale::get_state_option($params->{args}->{states_list});
    $states = [grep { $_->{value} ne '' } @$states];
    return $states;
};

sub _currencies_config {
    my $amt_precision = Format::Util::Numbers::get_precision_config()->{price};
    my $bet_limits    = BOM::Platform::Config::quants->{bet_limits};
    # As a stake_default (amount, which will be pre-populated for this currency on our website,
    # if there were no amount entered by client), we get max out of two minimal possible stakes.
    # Logic is copied from _build_staking_limits

    # Get available currencies
    my $payout_currencies = BOM::RPC::v3::Utility::filter_out_suspended_cryptocurrencies('costarica');

    my %currencies_config = map {
        $_ => {
            fractional_digits => $amt_precision->{$_},
            type              => LandingCompany::Registry::get_currency_type($_),
            stake_default     => max($bet_limits->{min_payout}->{volidx}->{$_}, $bet_limits->{min_payout}->{default}->{$_}) / 2,
            }
    } @{$payout_currencies};
    return \%currencies_config;
}

my $json = JSON::MaybeXS->new;

rpc website_status => sub {
    my $params = shift;

    my $app_config = BOM::Platform::Runtime->instance->app_config;

    return {
        terms_conditions_version => $app_config->cgi->terms_conditions_version,
        api_call_limits          => BOM::RPC::v3::Utility::site_limits,
        clients_country          => $params->{country_code},
        supported_languages      => $app_config->cgi->supported_languages,
        currencies_config        => _currencies_config(),
    };
};

1;
