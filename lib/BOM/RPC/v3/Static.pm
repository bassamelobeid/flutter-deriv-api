
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

use LandingCompany::Registry;
use Format::Util::Numbers qw/financialrounding/;
use DataDog::DogStatsd::Helper qw(stats_timing stats_gauge);
use Unicode::UTF8 qw(decode_utf8);
use JSON::MaybeXS;

use BOM::RPC::Registry '-dsl';

use BOM::Config::RedisReplicated;
use BOM::Config::Runtime;
use BOM::Platform::Locale;
use BOM::Config;
use BOM::Platform::Context qw (request);
use BOM::Database::ClientDB;
use BOM::RPC::v3::Utility;
use BOM::Config::CurrencyConfig;

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

    my $countries_instance = request()->brand->countries_instance;
    my $countries          = $countries_instance->countries;
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

        if ($countries_instance->restricted_country($country_code)) {
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

    my $amt_precision  = Format::Util::Numbers::get_precision_config()->{price};
    my $default_stakes = BOM::Config::quants()->{default_stake};
    # As a stake_default (amount, which will be pre-populated for this currency on our website,
    # if there were no amount entered by client), we get max out of two minimal possible stakes.
    # Logic is copied from _build_staking_limits

    my $transfer_limits = BOM::Config::CurrencyConfig::transfer_between_accounts_limits();
    my $transfer_fees   = BOM::Config::CurrencyConfig::transfer_between_accounts_fees();

    # Get available currencies
    my @all_currencies = keys %{LandingCompany::Registry::get('svg')->legal_allowed_currencies};

    my $suspended_currencies = BOM::RPC::v3::Utility::get_suspended_crypto_currencies();

    my %currencies_config = map {
        $_ => {
            fractional_digits         => $amt_precision->{$_},
            type                      => LandingCompany::Registry::get_currency_type($_),
            stake_default             => $default_stakes->{$_},
            is_suspended              => $suspended_currencies->{$_} ? 1 : 0,
            name                      => LandingCompany::Registry::get_currency_definition($_)->{name},
            transfer_between_accounts => {
                limits => $transfer_limits->{$_},
                fees   => $transfer_fees->{$_},
            }}
    } @all_currencies;

    return \%currencies_config;
}

rpc website_status => sub {
    my $params = shift;

    my $app_config = BOM::Config::Runtime->instance->app_config;
    return {
        terms_conditions_version => $app_config->cgi->terms_conditions_version,
        api_call_limits          => BOM::RPC::v3::Utility::site_limits,
        clients_country          => $params->{country_code},
        supported_languages      => $app_config->cgi->supported_languages,
        currencies_config        => _currencies_config(),

    };
};

1;
