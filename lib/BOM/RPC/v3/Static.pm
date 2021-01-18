
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
use JSON::MaybeXS qw(decode_json);

use Brands::Countries;

use BOM::RPC::Registry '-dsl';

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
        map  { +{code => $_, translated_name => $countries->localized_code2country($_, request()->language)} } $countries->all_country_codes
        )
    {
        my $country_code = $country_selection->{code};
        next if $country_code eq '';
        my $country_name = $country_selection->{translated_name};
        my $phone_idd    = $countries->idd_from_code($country_code);
        my $tin_format   = $countries_instance->get_tin_format($country_code);
        my $option       = {
            value => $country_code,
            text  => $country_name,
            $phone_idd  ? (phone_idd  => $phone_idd)  : (),
            $tin_format ? (tin_format => $tin_format) : ()};
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

    my $brand_name     = request()->brand->name;
    my $amt_precision  = Format::Util::Numbers::get_precision_config()->{price};
    my $default_stakes = BOM::Config::quants()->{default_stake};
    # As a stake_default (amount, which will be pre-populated for this currency on our website,
    # if there were no amount entered by client), we get max out of two minimal possible stakes.
    # Logic is copied from _build_staking_limits

    my $transfer_limits     = BOM::Config::CurrencyConfig::transfer_between_accounts_limits();
    my $transfer_limits_mt5 = BOM::Config::CurrencyConfig::mt5_transfer_limits($brand_name);
    my $transfer_fees       = BOM::Config::CurrencyConfig::transfer_between_accounts_fees();

    # Get available currencies
    my @all_currencies = LandingCompany::Registry::all_currencies();

    my $suspended_currencies = BOM::Config::CurrencyConfig::get_suspended_crypto_currencies();

    my %currencies_config = map {
        $_ => {
            fractional_digits         => $amt_precision->{$_},
            type                      => LandingCompany::Registry::get_currency_type($_),
            stake_default             => $default_stakes->{$_},
            is_suspended              => $suspended_currencies->{$_} ? 1 : 0,
            is_deposit_suspended      => BOM::RPC::v3::Utility::verify_cashier_suspended($_, 'deposit'),
            is_withdrawal_suspended   => BOM::RPC::v3::Utility::verify_cashier_suspended($_, 'withdrawal'),
            name                      => LandingCompany::Registry::get_currency_definition($_)->{name},
            transfer_between_accounts => {
                limits     => $transfer_limits->{$_},
                limits_mt5 => $transfer_limits_mt5->{$_},
                fees       => $transfer_fees->{$_},
            }}
    } @all_currencies;

    return \%currencies_config;
}

=head2 _crypto_config

Returns limits for cryptocurrencies in USD

=over 4

=item * text (curency name)

=item * amount (minimum withdrawal)

=back

Returns a HASH.

=cut

sub _crypto_config {

    my @all_crypto_currencies = LandingCompany::Registry::all_crypto_currencies();
    my %crypto_config;
    for my $currency (@all_crypto_currencies) {

        # To check if Exchange Rate is present currently [ Ex: IDK ]
        my $converted = eval {
            ExchangeRates::CurrencyConverter::convert_currency(BOM::Config::crypto()->{$currency}->{'withdrawal'}->{min_usd}, 'USD', $currency);
        } or undef;
        $crypto_config{$currency}->{minimum_withdrawal} = 0 + financialrounding('amount', $currency, $converted) if $converted;
    }

    return \%crypto_config;
}

rpc website_status => sub {
    my $params = shift;

    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->check_for_update;
    my $tnc_config  = $app_config->cgi->terms_conditions_versions;
    my $tnc_version = decode_json($tnc_config)->{request()->brand->name};

    return {
        terms_conditions_version => $tnc_version // '',
        api_call_limits          => BOM::RPC::v3::Utility::site_limits,
        clients_country          => $params->{country_code},
        supported_languages      => $app_config->cgi->supported_languages,
        currencies_config        => _currencies_config(),
        crypto_config            => _crypto_config(),
    };
};

=head2 trading_servers

    $trading_servers = trading_servers()

Takes a single C<$params> hashref containing the following keys:

=over 4

=item * client (deriv client object)

=over 4

=item * args which contains the following keys:

=item * platform (currently mt5)

=item * environment (currently env_01)

=back

=back

Returns an array of hashes for trade server config, sorted by
recommended flag and sorted by region

=cut

rpc "trading_servers",
    auth => 1,
    sub {
    my $params = shift;

    my $client      = $params->{client};
    my $platform    = $params->{args}{platform};
    my $environment = $params->{args}{environment};

    return generate_server_config(
        residence   => $client->residence,
        environment => $environment
    );

    };

=head2 generate_server_config

    generate_server_config(residence => $client->residence, environment => )

Return the array of hash of trade servers configuration
as per schema defined

=cut

sub generate_server_config {
    my (%args) = @_;

    return [] unless $args{residence};

    return [] if Brands::Countries->new()->restricted_country($args{residence});

    my %server_config = (
        "real01" => {
            geolocation => {
                region   => "Europe",
                location => "Ireland",
                sequence => 2
            },
            is_exclusive => 1,
            disabled     => 0,
            recommended  => 0,
        },
        "real02" => {
            geolocation => {
                region   => "Africa",
                location => "South Africa",
                sequence => 1
            },
            disabled    => 0,
            recommended => 0,
        },
        "real03" => {
            geolocation => {
                region   => "Asia",
                location => "Singapore",
                sequence => 1
            },
            disabled    => 0,
            recommended => 0,
        },
        "real04" => {
            geolocation => {
                region   => 'Europe',
                location => "Frankfurt",
                sequence => 1
            },
            disabled    => 0,
            recommended => 0,
        },
    );

    my $mt5_app_config        = BOM::Config::Runtime->instance->app_config->system->mt5;
    my $server_routing_config = BOM::Config::mt5_server_routing();

    my $is_mt5_completely_suspended = $mt5_app_config->suspend->all;
    my $account_type                = 'real';
    my $residence_config            = $server_routing_config->{real}->{$args{residence}};

    $account_type .= $residence_config->{synthetic};

    $server_config{$account_type}{recommended} = 1;

    # its real01
    if ($server_config{$account_type}{is_exclusive}) {
        delete $server_config{$account_type}{is_exclusive};

        $server_config{$account_type}{environment} = $args{environment};
        $server_config{$account_type}{id}          = $account_type;
        $server_config{$account_type}{disabled}    = $is_mt5_completely_suspended ? 1 : $mt5_app_config->suspend->$account_type->all;

        push @{$server_config{$account_type}{supported_accounts}}, ('gaming', 'financial', 'financial_stp');

        return [$server_config{$account_type}];
    }

    my @response = ();
    foreach my $server_key (keys %server_config) {
        next if $server_config{$server_key}{is_exclusive};

        $server_config{$server_key}{environment} = $args{environment};
        $server_config{$server_key}{id}          = $server_key;
        $server_config{$server_key}{disabled}    = $is_mt5_completely_suspended ? 1 : $mt5_app_config->suspend->$server_key->all;

        push @{$server_config{$server_key}{supported_accounts}}, 'gaming';

        push @response, $server_config{$server_key};
    }

    return [sort { $b->{recommended} cmp $a->{recommended} or $a->{geolocation}{region} cmp $b->{geolocation}{region} } @response];
}

1;
