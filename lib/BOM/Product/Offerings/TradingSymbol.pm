package BOM::Product::Offerings::TradingSymbol;

use strict;
use warnings;

use Exporter qw(import);
our @EXPORT_OK = qw(get_symbols _filter_no_business_profiles);

use BOM::Config::Runtime;
use BOM::Config::Chronicle;
use BOM::Config::Redis;
use BOM::MarketData qw(create_underlying);
use BOM::Product::Exception;

use Format::Util::Numbers qw/roundcommon/;
use LandingCompany::Registry;
use Cache::RedisDB;
use Finance::Underlying;
use Quant::Framework;
use Date::Utility;
use Brands;
use JSON::MaybeXS qw(decode_json);

use constant {
    NAMESPACE      => 'TRADING_SYMBOL',
    SECONDS_IN_DAY => 86400,
};

=head2 get_symbols

Returns a array reference of trading symbols for the given parameters

=over 4

=item * landing_company_name - landing company short name (required, default to virtual)

=item * country_code - 2-letter country code

=item * app_id - application id

=back

=cut

sub get_symbols {
    my $args = shift;

    my $landing_company_name = $args->{landing_company_name} // 'virtual';
    my $type                 = $args->{type}                 // 'full';
    my $landing_company      = LandingCompany::Registry->by_name($landing_company_name);
    my $contract_type        = $args->{contract_type}    // [];
    my $barrier_category     = $args->{barrier_category} // [];

    BOM::Product::Exception->throw(error_code => 'OfferingsInvalidLandingCompany') unless ($landing_company);

    my $country_code       = $args->{country_code};
    my $runtime            = BOM::Config::Runtime->instance;
    my $appconfig_revision = $runtime->app_config->loaded_revision // 0;
    my $brands             = $args->{brands}                       // Brands->new;
    my $app_offerings      = defined $args->{app_id} ? $brands->get_app($args->{app_id})->offerings() : 'default';

    my $active_symbols = [];    # API response expects an array eventhough it is empty

    my $offerings_obj;
    if ($country_code) {
        $offerings_obj = $landing_company->basic_offerings_for_country($country_code, $runtime->get_offerings_config, $app_offerings);
    } else {
        $offerings_obj = $landing_company->basic_offerings($runtime->get_offerings_config, $app_offerings);
    }

    my ($namespace, $key) = (
        'trading_symbols', join('::', (sort(@$contract_type), sort(@$barrier_category), $offerings_obj->name, $appconfig_revision, $app_offerings)));

    if (my $cached_symbols = Cache::RedisDB->get($namespace, $key)) {
        $active_symbols = $cached_symbols;
    } else {
        my $leaderboard = _get_leaderboard($offerings_obj);
        my @all_active;
        my %query_params;

        if (defined $contract_type && @$contract_type) {
            $query_params{contract_type} = $contract_type;
        }
        if (defined $barrier_category && @$barrier_category) {
            $query_params{barrier_category} = $barrier_category;
        }
        @all_active = $offerings_obj->query(\%query_params, ['underlying_symbol']);

        # symbols would be active if we allow forward starting contracts on them.
        my %forward_starting = map { $_ => 1 } $offerings_obj->query({start_type => 'forward'}, ['underlying_symbol']);
        foreach my $symbol (@all_active) {
            my $desc = _description($symbol) or next;
            # leaderboard will have data on transacted symbols, default to total number symbols (E.g. last in display_order if
            # there is no transaction on a particular symbol).
            $desc->{display_order}          = $leaderboard->{$symbol} // scalar(@all_active);
            $desc->{allow_forward_starting} = $forward_starting{$symbol} ? 1 : 0;
            push @{$active_symbols}, $desc;
        }

        my $cache_interval = 30;
        Cache::RedisDB->set($namespace, $key, $active_symbols, $cache_interval - time % $cache_interval);
    }

    # filter no_business risk profiles
    my $data             = _get_product_profiles();
    my %no_business_data = _filter_no_business_profiles($landing_company_name, $data);

    @$active_symbols =
        grep { !$no_business_data{$_->{submarket}} && !$no_business_data{$_->{symbol}} && !$no_business_data{$_->{market}} } @$active_symbols;

    return {symbols => $type eq 'brief' ? _trim($active_symbols) : $active_symbols};
}

=head2 _trim

Trim active symbols to return brief information.

=cut

{
    my @brief =
        qw(market submarket submarket_display_name pip symbol symbol_type market_display_name exchange_is_open display_name  is_trading_suspended allow_forward_starting subgroup subgroup_display_name display_order);

    sub _trim {
        my $active_symbols = shift;

        my @trimmed;
        foreach my $details ($active_symbols->@*) {
            push @trimmed, +{map { $_ => $details->{$_} } @brief};
        }

        return \@trimmed;
    }
}

=head2 _description

Returns an hash reference of configuration details for a symbol

=cut

sub _description {
    my $symbol = shift;

    my $ul                      = create_underlying($symbol) || return;
    my $trading_calendar        = Quant::Framework->new->trading_calendar(BOM::Config::Chronicle::get_chronicle_reader);
    my $exchange_is_open        = $trading_calendar->is_open_at($ul->exchange, Date::Utility->new);
    my $ohlc                    = $ul->realtime_ohlc_for(SECONDS_IN_DAY);
    my $daily_percentage_change = exists $ohlc->{open} ? (roundcommon(0.01, ($ul->spot - $ohlc->{open}) / $ohlc->{open} * 100)) : '0.00';

    my $response = {
        symbol                    => $symbol,
        display_name              => $ul->display_name,
        symbol_type               => $ul->instrument_type,
        market_display_name       => $ul->market->display_name,
        market                    => $ul->market->name,
        submarket                 => $ul->submarket->name,
        submarket_display_name    => $ul->submarket->display_name,
        subgroup                  => $ul->submarket->subgroup->{name},
        subgroup_display_name     => $ul->submarket->subgroup->{display_name},
        exchange_is_open          => $exchange_is_open || 0,
        is_trading_suspended      => 0,                                 # please remove this if we ever move to a newer API version of active_symbols
        pip                       => $ul->pip_size . "",
        exchange_name             => $ul->exchange_name,
        delay_amount              => $ul->delay_amount,
        quoted_currency_symbol    => $ul->quoted_currency_symbol,
        intraday_interval_minutes => $ul->intraday_interval->minutes,
        spot                      => $ul->spot,
        spot_time                 => $ul->spot_time // '',
        spot_age                  => $ul->spot_age,
        spot_percentage_change    => $daily_percentage_change,
    };

    return $response;
}

=head2 _get_leaderboard

Get leaderboard by market.

=cut

sub _get_leaderboard {
    my $offerings = shift;

    my $redis = BOM::Config::Redis::redis_transaction();
    my %leaderboard;
    foreach my $market ($offerings->values_for_key('market')) {
        # counter separate by market
        my $counter = 0;
        foreach my $symbol ($redis->zrevrangebyscore('SYMBOL_LEADERBOARD::' . $market, 'inf', 0)->@*) {
            $leaderboard{$symbol} = $counter++;
        }
    }

    return \%leaderboard;
}

=head2 _get_product_profiles

get data [custom_product_profile] from redis 

=cut

sub _get_product_profiles {
    my $app_config              = BOM::Config::Runtime->instance->app_config;
    my $custom_product_profiles = $app_config->get('quants.custom_product_profiles');
    return decode_json($custom_product_profiles);
}

=head2 _is_no_business_contract

return true if meets the requirements

=cut

sub _is_no_business_contract {
    my ($contract, $landing_company) = @_;

    return (   $contract->{risk_profile}
            && $contract->{risk_profile} eq "no_business"
            && (!$contract->{landing_company} || $contract->{landing_company} eq $landing_company)
            && (!$contract->{expiry_type} && !$contract->{start_time})
            && (!$contract->{contract_category}));
}

=head2 _split_string

split strings and store into hash

=cut

sub _split_string {
    my $string = shift;
    my %split_data;

    if (defined $string) {
        my @split_strings = split(/,/, $string);
        foreach my $split_string (@split_strings) {
            if (defined $split_string) {
                $split_data{$split_string} = 1;
            }
        }
    }
    return \%split_data;
}

=head2 _filter_no_business_profiles

Filter No Business product profiles

=cut

sub _filter_no_business_profiles {
    my ($landing_company, $data) = @_;
    my %no_business_data;
    # storing market, submarket or underlying_symbol having risk_profile = no_business into new no_business_data
    for my $contract (values %{$data}) {
        if (_is_no_business_contract($contract, $landing_company)) {
            if (($contract->{market} || $contract->{submarket}) && $contract->{underlying_symbol}) {
                %no_business_data = (%no_business_data, %{_split_string($contract->{underlying_symbol})});
            } elsif (($contract->{market} && $contract->{submarket})) {
                %no_business_data = (%no_business_data, %{_split_string($contract->{submarket})});
            } elsif ($contract->{market}) {
                %no_business_data = (%no_business_data, %{_split_string($contract->{market})});
            } elsif ($contract->{submarket}) {
                %no_business_data = (%no_business_data, %{_split_string($contract->{submarket})});
            } elsif ($contract->{underlying_symbol}) {
                %no_business_data = (%no_business_data, %{_split_string($contract->{underlying_symbol})});
            }
        }

    }

    return %no_business_data;
}

1;
