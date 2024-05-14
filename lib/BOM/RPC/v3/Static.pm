
=head1 NAME

BOM::RPC::v3::Static

=head1 DESCRIPTION

This is a package containing various utility functions for bom-rpc.

=cut

package BOM::RPC::v3::Static;

use strict;
use warnings;

no indirect;

use List::Util    qw( min max any uniq);
use List::UtilsBy qw(nsort_by);
use Array::Utils  qw(intersect);
use Time::HiRes   ();

use BOM::Config::Quants qw(get_exchangerates_limit);
use LandingCompany::Registry;
use Format::Util::Numbers;
use DataDog::DogStatsd::Helper qw(stats_timing stats_gauge);
use Unicode::UTF8              qw(decode_utf8);
use JSON::MaybeXS              qw(decode_json);
use JSON::MaybeUTF8            qw(:v1);
use POSIX                      qw( floor );
use Math::BigFloat;

use BOM::RPC::Registry '-dsl';

use BOM::Config::Runtime;
use BOM::Platform::Locale;
use BOM::Platform::Context qw (request);
use BOM::Platform::Utility;
use BOM::Database::ClientDB;
use BOM::RPC::v3::Utility;
use BOM::Config::CurrencyConfig;
use BOM::Config::Onfido;
use BOM::Platform::Context qw(localize);
use BOM::TradingPlatform::DXTrader;
use BOM::Config::P2P;
use BOM::Config::Runtime;
use BOM::Config::Redis;
use LandingCompany::Registry;
use Business::Config::Country;
use Locale::Country::Extra;

use constant WEBSITE_STATUS_KEY_NAMESPACE => 'WEBSITE_STATUS';
use constant WEBSITE_CONFIG_KEY_NAMESPACE => 'WEBSITE_CONFIG';
use constant STATIC_CACHE_TTL             => 10;

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

    my $countries = Locale::Country::Extra->new();

    my $country_list = Business::Config::Country->new()->list();

    my @sorted_list =
        sort { $a->{name} cmp $b->{name} }
        map  { +{code => $_, name => $countries->localized_code2country($_, request()->language) // $country_list->{$_}->{name},} }
        keys $country_list->%*;

    foreach my $country_data (@sorted_list) {
        my $country_code = $country_data->{code};
        next unless $country_code;

        my $country_name   = $country_data->{name};
        my $country_config = $country_list->{$country_code};
        my $phone_idd      = $country_config->{phone_idd};
        my $tin_format     = $country_config->{common_reporting_standard}->{tax}->{tin_format};

        my $poi_config        = $country_config->{know_your_customer}->{authentication}->{identity_verification};
        my $has_visual_sample = $poi_config->{provider}->{idv}->{has_visual_sample};

        my $app_config = BOM::Config::Runtime->instance->app_config;
        $app_config->check_for_update;
        my $onfido_suspended    = $app_config->system->suspend->onfido;
        my $documents_supported = BOM::User::Onfido::supported_documents($country_code);

        # Special case for Nigeria's NIN
        if ($documents_supported->{identification_number_document}) {
            delete $documents_supported->{identification_number_document};
            $documents_supported->{national_identity_card} = {display_name => 'National Identity Card'};
        }

        # Special case for Malaysia's national id
        if ($documents_supported->{service_id_card}) {
            delete $documents_supported->{service_id_card};
            $documents_supported->{national_identity_card} = {display_name => 'National Identity Card'};
        }

        my $has_tin_format = scalar $tin_format->@*;

        my $option = {
            value => $country_code,
            text  => $country_name,
            $phone_idd      ? (phone_idd  => $phone_idd)  : (),
            $has_tin_format ? (tin_format => $tin_format) : (),
            # KYC in general is highly dependent on feature flags and dynamic config
            identity => {
                services => {
                    idv => {
                        documents_supported  => BOM::User::IdentityVerification::supported_documents($country_code),
                        is_country_supported => BOM::Platform::Utility::has_idv(country => $country_code),
                        has_visual_sample    => $has_visual_sample ? 1 : 0,
                    },
                    onfido => {
                        documents_supported  => $documents_supported,
                        is_country_supported => (!$onfido_suspended && BOM::Config::Onfido::is_country_supported($country_code)) ? 1 : 0,
                    }
                },
            }};

        my $landing_company = $country_config->{landing_company};
        my $signup_config   = $country_config->{signup};
        my $allowed_country = $landing_company->{default} ne 'none';
        my $disabled        = !$allowed_country || (!$signup_config->{account} && !$signup_config->{partners});

        $option->{disabled}                                  = 'DISABLED' if $disabled;
        $option->{selected}                                  = 'selected' if request()->country_code eq $country_code && !$option->{disabled};
        $option->{account_opening_self_declaration_required} = 1          if $signup_config->{self_declaration};

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
    my $country = shift;

    my $brand_name     = request()->brand->name;
    my $amt_precision  = Format::Util::Numbers::get_precision_config()->{price};
    my $default_stakes = BOM::Config::quants()->{default_stake};
    # As a stake_default (amount, which will be pre-populated for this currency on our website,
    # if there were no amount entered by client), we get max out of two minimal possible stakes.
    # Logic is copied from _build_staking_limits

    my $transfer_limits         = BOM::Config::CurrencyConfig::transfer_between_accounts_limits();
    my $transfer_limits_mt5     = BOM::Config::CurrencyConfig::platform_transfer_limits('MT5', $brand_name);
    my $transfer_fees           = BOM::Config::CurrencyConfig::transfer_between_accounts_fees($country);
    my $transfer_limits_dxtrade = BOM::Config::CurrencyConfig::platform_transfer_limits('dxtrade', $brand_name);
    my $transfer_limits_derivez = BOM::Config::CurrencyConfig::platform_transfer_limits('derivez', $brand_name);
    my $transfer_limits_ctrader = BOM::Config::CurrencyConfig::platform_transfer_limits('ctrader', $brand_name);

    # Get available currencies
    my @all_currencies = LandingCompany::Registry::all_currencies();

    my $suspended_currencies = BOM::Config::CurrencyConfig::get_suspended_crypto_currencies();

    my %currencies_config = map {
        $_ => {
            fractional_digits         => $amt_precision->{$_},
            type                      => LandingCompany::Registry::get_currency_type($_),
            stake_default             => get_exchangerates_limit($default_stakes->{$_}, $_),
            is_suspended              => $suspended_currencies->{$_} ? 1 : 0,
            is_deposit_suspended      => BOM::RPC::v3::Utility::verify_cashier_suspended($_, 'deposit'),
            is_withdrawal_suspended   => BOM::RPC::v3::Utility::verify_cashier_suspended($_, 'withdrawal'),
            name                      => LandingCompany::Registry::get_currency_definition($_)->{name},
            transfer_between_accounts => {
                limits         => $transfer_limits->{$_},
                limits_mt5     => $transfer_limits_mt5->{$_},
                limits_dxtrade => $transfer_limits_dxtrade->{$_},
                limits_derivez => $transfer_limits_derivez->{$_},
                limits_ctrader => $transfer_limits_ctrader->{$_},
                fees           => $transfer_fees->{$_},
            }}
    } @all_currencies;

    return \%currencies_config;
}

=head2 _mt5_status

Returns mt5 platform suspension status

Returns a HASH.

=cut

sub _mt5_status {
    my $mt5_real_servers = BOM::Config::MT5->new(group_type => 'real')->servers;
    my $mt5_demo_servers = BOM::Config::MT5->new(group_type => 'demo')->servers;

    my (@real_objects, @demo_objects);
    my ($server_name, $platform, $server_number);

    my $mt5_api_suspend_config = BOM::Config::Runtime->instance->app_config->system->mt5->suspend;

    # Populating demo mt5 trading server objects.
    foreach my $number (keys $mt5_demo_servers->@*) {
        ($server_name) = %{$mt5_demo_servers->[$number]};
        $server_name =~ m/p(\d+)_ts(\d+)/;

        $platform      = int($1);
        $server_number = int($2);

        push @demo_objects,
            {
            all           => $mt5_api_suspend_config->all || $mt5_api_suspend_config->demo->$server_name->all,
            server_number => $server_number,
            platform      => $platform,
            };
    }

    # Populating real mt5 trading server objects.
    foreach my $number (keys $mt5_real_servers->@*) {
        ($server_name) = %{$mt5_real_servers->[$number]};
        $server_name =~ m/p(\d+)_ts(\d+)/;

        $platform      = int($1);
        $server_number = int($2);

        push @real_objects,
            {
            all         => $mt5_api_suspend_config->all || $mt5_api_suspend_config->real->$server_name->all,
            withdrawals => $mt5_api_suspend_config->all
                || $mt5_api_suspend_config->withdrawals
                || $mt5_api_suspend_config->real->$server_name->withdrawals,
            deposits => $mt5_api_suspend_config->all || $mt5_api_suspend_config->deposits || $mt5_api_suspend_config->real->$server_name->deposits,
            server_number => $server_number,
            platform      => $platform,
            };
    }

    return {
        demo => [@demo_objects],
        real => [@real_objects]};
}

=head2 _dxtrade_status

Returns Deriv X platform suspension status

Returns a HASH.

=cut

sub _dxtrade_status {
    my $dxtrade_servers_config = BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend;

    return {
        all  => $dxtrade_servers_config->all,
        demo => $dxtrade_servers_config->all || $dxtrade_servers_config->demo,
        real => $dxtrade_servers_config->all || $dxtrade_servers_config->real
    };
}

rpc website_status => sub {
    my $params = shift;

    my $result  = {};
    my $country = $params->{residence} // $params->{country_code};
    my $key     = $country ? WEBSITE_STATUS_KEY_NAMESPACE . "::" . lc($country) : WEBSITE_STATUS_KEY_NAMESPACE;

    $result = get_static_data($key);
    return $result if keys %$result;

    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->check_for_update;

    my $tnc_config   = $app_config->cgi->terms_conditions_versions;
    my $tnc_version  = decode_json($tnc_config)->{request()->brand->name};
    my $broker_codes = [keys BOM::Config::broker_databases()->%*];
    $result = {
        terms_conditions_version => $tnc_version // '',
        api_call_limits          => BOM::RPC::v3::Utility::site_limits,
        clients_country          => $params->{country_code},
        supported_languages      => $app_config->cgi->supported_languages,
        broker_codes             => $broker_codes,
        currencies_config        => _currencies_config($country),
        mt5_status               => _mt5_status(),
        dxtrade_status           => _dxtrade_status(),
        payment_agents           => {
            initial_deposit_per_country => decode_json($app_config->payment_agents->initial_deposit_per_country),
        },
    };

    if (my $p2p_advert_config = BOM::Config::P2P::advert_config()->{$country // ''}) {
        my $p2p_config           = $app_config->payments->p2p;
        my $local_currency       = BOM::Config::CurrencyConfig::local_currency_for_country(country => $country);
        my $exchange_rate        = BOM::User::Utility::p2p_exchange_rate($local_currency);
        my $float_range          = BOM::Config::P2P::currency_float_range($local_currency);
        my %all_local_currencies = %BOM::Config::CurrencyConfig::ALL_CURRENCIES;
        my @p2p_countries        = keys BOM::Config::P2P::available_countries()->%*;
        my @p2p_currencies       = split ',', (BOM::Config::Redis->redis_p2p->get('P2P::LOCAL_CURRENCIES') // '');

        my @local_currencies;
        for my $symbol (sort keys %all_local_currencies) {
            next unless intersect(@p2p_countries, $all_local_currencies{$symbol}->{countries}->@*);
            push @local_currencies, {
                symbol       => $symbol,
                display_name => localize($all_local_currencies{$symbol}->{name}),    # transations added in BOM::Backoffice::Script::ExtraTranslations
                has_adverts  => (any { $symbol eq $_ } @p2p_currencies) ? 1 : 0,
                $symbol eq $local_currency ? (is_default => 1) : (),
            };
        }

        $result->{p2p_config} = {
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
            supported_currencies        => [sort(uniq($p2p_config->available_for_currencies->@*))],
            disabled                    => (
                not $p2p_config->enabled
                    or $app_config->system->suspend->p2p
            ) ? 1 : 0,
            payment_methods_enabled => $p2p_config->payment_methods_enabled,
            review_period           => $p2p_config->review_period,
            fixed_rate_adverts      => $p2p_advert_config->{fixed_ads},
            float_rate_adverts      => $p2p_advert_config->{float_ads},
            float_rate_offset_limit => Math::BigFloat->new($float_range)->bdiv(2)->bfround(-2, 'trunc')->bstr,
            $p2p_advert_config->{deactivate_fixed}       ? (fixed_rate_adverts_end_date => $p2p_advert_config->{deactivate_fixed}) : (),
            ($exchange_rate->{source} // '') eq 'manual' ? (override_exchange_rate      => $exchange_rate->{quote})                : (),
            feature_level            => $p2p_config->feature_level,
            local_currencies         => \@local_currencies,
            cross_border_ads_enabled => (any { lc($_) eq $country } $p2p_config->cross_border_ads_restricted_countries->@*) ? 0 : 1,
            block_trade              => {
                disabled              => $p2p_config->block_trade->enabled ? 0 : 1,
                maximum_advert_amount => $p2p_config->block_trade->maximum_advert,
            },
        };
    }

    set_static_data($key, $result);

    return $result;
};

=head2 website_config

An RPC subroutine that retrieves and returns the website configuration based on the provided country code. Along with feature flags, it also returns the supported currencies, payment agents, and supported languages.

Takes a single C<$params>.

=over 4

=item * C<$params> - a HASH reference containing the following keys:

=over 4

=item * C<country_code> - a 2-letter country code

=back

=back

Returns a HASH containing the following keys:

=over 4

=item * C<feature_flags> - an array of feature flags

=item * C<currencies_config> - a HASH containing the supported currencies

=item * C<payment_agents> - a HASH containing the payment agents

=item * C<supported_languages> - an array of supported languages

=item * C<terms_conditions_version> - the terms and conditions version

=back

=cut

rpc website_config => sub {
    my $params = shift;

    my $result  = {};
    my $country = $params->{residence} // $params->{country_code};
    my $key     = $country ? WEBSITE_CONFIG_KEY_NAMESPACE . "::" . lc($country) : WEBSITE_CONFIG_KEY_NAMESPACE;

    $result = get_static_data($key);
    return $result if keys %$result;

    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->check_for_update;

    my @feature_flags;
    push @feature_flags, 'signup_with_optional_email_verification' if $app_config->email_verification->suspend->virtual_accounts;
    my $terms_conditions_versions = decode_json($app_config->cgi->terms_conditions_versions)->{request()->brand->name};

    $result = {
        feature_flags     => \@feature_flags,
        currencies_config => _currencies_config($country),
        payment_agents    => {
            initial_deposit_per_country => decode_json($app_config->payment_agents->initial_deposit_per_country),
        },
        supported_languages      => $app_config->cgi->supported_languages,
        terms_conditions_version => $terms_conditions_versions // '',
    };

    set_static_data($key, $result);
    return $result;
};

=head2 get_static_data

Returns the static cache stored in Redis for the provided key

Takes a single C<$key>.

=over 4

=item * C<$key> - a key string for the redis

=back

=cut

sub get_static_data {
    my $key = shift;

    my $data = BOM::Config::Redis::redis_rpc_write()->get($key);
    return {} unless $data;

    return decode_json_utf8($data);
}

=head2 set_static_data

Set the static data in Redis for the key and value pair

Takes a C<$key>.

Takes a C<$value>.

=over 4

=item * C<$key> - a key string for the redis

=item * C<$value> - a value (a hash) to store against the key provided

=back

=cut

sub set_static_data {
    my ($key, $value) = @_;
    # if condition is added to prevent warnings
    # and for test to update it to 0 to stop caching functionality
    BOM::Config::Redis::redis_rpc_write()->set($key, encode_json_utf8($value), 'NX', 'EX', __PACKAGE__->STATIC_CACHE_TTL)
        if __PACKAGE__->STATIC_CACHE_TTL > 0;
    return undef;
}

=head2 trading_platforms

Return static configuration about the trading platforms currently supported.

=cut

rpc trading_platforms => auth => [],
    sub {
    my $config = Business::Config::LandingCompany->new()->trading_platforms();
    return $config->{trading_platforms}->{types};
    };

1;
