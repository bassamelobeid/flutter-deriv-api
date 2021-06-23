
=head1 NAME

BOM::RPC::v3::Static

=head1 DESCRIPTION

This is a package containing various utility functions for bom-rpc.

=cut

package BOM::RPC::v3::Static;

use strict;
use warnings;

no indirect;

use List::Util qw( min max any );
use List::UtilsBy qw(nsort_by);
use Time::HiRes ();

use LandingCompany::Registry;
use Format::Util::Numbers qw/financialrounding/;
use DataDog::DogStatsd::Helper qw(stats_timing stats_gauge);
use Unicode::UTF8 qw(decode_utf8);
use JSON::MaybeXS qw(decode_json);
use POSIX qw( floor );

use BOM::RPC::Registry '-dsl';

use BOM::Config::Runtime;
use BOM::Platform::Locale;
use BOM::Platform::Context qw (request);
use BOM::Database::ClientDB;
use BOM::RPC::v3::Utility;
use BOM::Config::CurrencyConfig;
use BOM::Config::Onfido;
use BOM::Platform::Context qw(localize);

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
        my $country_name       = $country_selection->{translated_name};
        my $phone_idd          = $countries->idd_from_code($country_code);
        my $tin_format         = $countries_instance->get_tin_format($country_code);
        my $idv_config         = $countries_instance->get_idv_config($country_code) // {};
        my $idv_docs_supported = $idv_config->{document_types}                      // {};
        my $has_visual_sample  = $idv_config->{has_visual_sample}                   // 0;

        my $option = {
            value => $country_code,
            text  => $country_name,
            $phone_idd  ? (phone_idd  => $phone_idd)  : (),
            $tin_format ? (tin_format => $tin_format) : (),
            identity => {
                services => {
                    idv => {
                        documents_supported => +{
                            map { (
                                    $_ => {
                                        display_name => localize($idv_docs_supported->{$_}->{display_name}),
                                        format       => $idv_docs_supported->{$_}->{format},
                                    })
                            } keys $idv_docs_supported->%*
                        },
                        is_country_supported => $countries_instance->is_idv_supported($country_code) // 0,
                        has_visual_sample    => $has_visual_sample
                    },
                    onfido => {
                        documents_supported =>
                            +{map { _onfido_doc_type($_) } BOM::Config::Onfido::supported_documents_for_country($country_code)->@*},
                        is_country_supported => BOM::Config::Onfido::is_country_supported($country_code),
                    }
                },
            }};
        if ($countries_instance->restricted_country($country_code)
            || !$countries_instance->is_signup_allowed($country_code))
        {
            $option->{disabled} = 'DISABLED';
        } elsif (request()->country_code eq $country_code) {
            $option->{selected} = 'selected';
        }
        push @$residence_countries_list, $option;
    }

    return $residence_countries_list;
};

=head2 _onfido_doc_type

Process the Onfido doc types given into the hash form expected by the api schema response,
since Onfido config provides a flat list of doc types is somewhat complicated to give it
the conforming structure.

It takes the following parameter:

=over 4

=item * C<$doc_type> - the given onfido doc type

=back

Returns a single element hash as:

( $snake_case_key => {
    display_name => $doc_type,
})

=cut

sub _onfido_doc_type {
    my ($doc_type) = $_;
    my $snake_case_key = lc $doc_type =~ s/\s+/_/rg;

    return (
        $snake_case_key => {
            display_name => $doc_type,
        });
}

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

    my $transfer_limits         = BOM::Config::CurrencyConfig::transfer_between_accounts_limits();
    my $transfer_limits_mt5     = BOM::Config::CurrencyConfig::platform_transfer_limits('MT5', $brand_name);
    my $transfer_fees           = BOM::Config::CurrencyConfig::transfer_between_accounts_fees();
    my $transfer_limits_dxtrade = BOM::Config::CurrencyConfig::platform_transfer_limits('dxtrade', $brand_name);

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
                limits         => $transfer_limits->{$_},
                limits_mt5     => $transfer_limits_mt5->{$_},
                limits_dxtrade => $transfer_limits_dxtrade->{$_},
                fees           => $transfer_fees->{$_},
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
    my $p2p_config  = $app_config->payments->p2p;

    return {
        terms_conditions_version => $tnc_version // '',
        api_call_limits          => BOM::RPC::v3::Utility::site_limits,
        clients_country          => $params->{country_code},
        supported_languages      => $app_config->cgi->supported_languages,
        currencies_config        => _currencies_config(),
        crypto_config            => _crypto_config(),
        p2p_config               => {
            $p2p_config->archive_ads_days ? (adverts_archive_period => $p2p_config->archive_ads_days) : (),
            order_payment_period        => floor($p2p_config->order_timeout / 60),
            cancellation_block_duration => $p2p_config->cancellation_barring->bar_time,
            cancellation_grace_period   => $p2p_config->cancellation_grace_period,
            cancellation_limit          => $p2p_config->cancellation_barring->count,
            cancellation_count_period   => $p2p_config->cancellation_barring->period,
            maximum_advert_amount       => $p2p_config->limits->maximum_advert,
            maximum_order_amount        => $p2p_config->limits->maximum_order,
            adverts_active_limit        => $p2p_config->limits->maximum_ads_per_type,
            order_daily_limit           => $p2p_config->limits->count_per_day_per_client,
        }};
};

1;
