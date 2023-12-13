
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
use LandingCompany::Registry;

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
        my $phone_idd          = $countries_instance->idd_code_for_country($country_code);
        my $tin_format         = $countries_instance->get_tin_format($country_code);
        my $idv_config         = $countries_instance->get_idv_config($country_code) // {};
        my $idv_docs_supported = $idv_config->{document_types}                      // {};
        my $has_visual_sample  = $idv_config->{has_visual_sample}                   // 0;
        my $app_config         = BOM::Config::Runtime->instance->app_config;
        $app_config->check_for_update;
        my $onfido_suspended = $app_config->system->suspend->onfido;
        my $option           = {
            value => $country_code,
            text  => $country_name,
            $phone_idd  ? (phone_idd  => $phone_idd)  : (),
            $tin_format ? (tin_format => $tin_format) : (),
            identity => {
                services => {
                    idv => {
                        documents_supported => +{
                            map {
                                (
                                    $_ => {
                                        display_name => localize($idv_docs_supported->{$_}->{display_name}),
                                        format       => $idv_docs_supported->{$_}->{format},
                                        $idv_docs_supported->{$_}->{additional} ? (additional => $idv_docs_supported->{$_}->{additional}) : (),
                                    })
                            } grep {
                                !$idv_docs_supported->{$_}->{disabled} && BOM::Platform::Utility::has_idv(
                                    country       => $country_code,
                                    document_type => $_
                                )
                            } keys $idv_docs_supported->%*
                        },
                        is_country_supported => BOM::Platform::Utility::has_idv(
                            country  => $country_code,
                            provider => $idv_config->{provider}
                        ),
                        has_visual_sample => $has_visual_sample
                    },
                    onfido => {
                        documents_supported =>
                            +{map { _onfido_doc_type($_) } BOM::Config::Onfido::supported_documents_for_country($country_code)->@*},
                        is_country_supported => (!$onfido_suspended && BOM::Config::Onfido::is_country_supported($country_code)) ? 1 : 0,
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
    my $params     = shift;
    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->check_for_update;
    my $tnc_config   = $app_config->cgi->terms_conditions_versions;
    my $tnc_version  = decode_json($tnc_config)->{request()->brand->name};
    my $country      = $params->{residence} // $params->{country_code};
    my $broker_codes = [keys BOM::Config::broker_databases()->%*];
    my $result       = {
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

    return $result;
};

1;
