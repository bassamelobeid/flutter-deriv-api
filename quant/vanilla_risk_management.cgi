#!/etc/rmg/bin/perl

package main;

use strict;
use warnings;
use JSON::MaybeUTF8 qw(:v1);
use List::Util      qw(min max any);
use YAML::XS        qw(LoadFile);

use BOM::Backoffice::Sysinit ();
use BOM::Config::Runtime;
use LandingCompany::Registry;

BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation('Vanilla Risk Management Tool');

my $disabled_write = not BOM::Backoffice::Auth::has_quants_write_access();

my $limit_defs = BOM::Config::quants()->{risk_profile};
delete $limit_defs->{no_business};    # no_business should be set in product management tool
my @currencies = sort keys %{$limit_defs->{low_risk}{multiplier}};
my @stake_rows;

my $app_config = BOM::Config::Runtime->instance->app_config;

my $offerings_config = {
    action          => 'buy',
    loaded_revision => 0,
};

my $offerings  = LandingCompany::Registry->by_name('virtual')->basic_offerings($offerings_config);
my @symbols_fx = sort $offerings->query({
        contract_category => 'vanilla',
        market            => 'forex'
    },
    ['underlying_symbol']);
my @symbols_commodities = sort $offerings->query({
        contract_category => 'vanilla',
        market            => 'commodities'
    },
    ['underlying_symbol']);

our @symbols_synthetics = sort $offerings->query({
        contract_category => 'vanilla',
        market            => 'synthetic_index'
    },
    ['underlying_symbol']);
our @symbols_financials = (@symbols_fx, @symbols_commodities);

foreach my $risk_level (keys %$limit_defs) {
    my $s = decode_json_utf8($app_config->get("quants.vanilla.risk_profile.$risk_level"));
    my @stake;
    my @obsolete_currencies = ('USB', 'PAX', 'TUSD', 'DAI', 'USDK', 'BUSD', 'IDK', 'EURS');

    foreach my $ccy (sort keys %{$s}) {
        if (any { $_ eq $ccy } @obsolete_currencies) {
            next;
        }

        push @stake, $s->{$ccy};
    }

    push @stake_rows, [$risk_level, @stake];
}

Bar("Vanilla Risk Profile Definition");

BOM::Backoffice::Request::template()->process(
    'backoffice/vanilla_profile_definitions.html.tt',
    {
        currencies  => \@currencies,
        stake_rows  => \@stake_rows,
        definitions => $limit_defs,
    }) || die BOM::Backoffice::Request::template()->error;

Bar("Vanilla Affiliate Commission");

BOM::Backoffice::Request::template()->process(
    'backoffice/vanilla_affiliate_commission.html.tt',
    {
        vanilla_upload_url => request()->url_for('backoffice/quant/market_data_mgmt/update_vanilla_config.cgi'),
        existing_config    => _get_existing_vanilla_commission_config(),
        disabled           => $disabled_write,
    }) || die BOM::Backoffice::Request::template()->error;

Bar("Vanilla Per Symbol Config");

BOM::Backoffice::Request::template()->process(
    'backoffice/vanilla_per_symbol_configuration.html.tt',
    {
        vanilla_upload_url => request()->url_for('backoffice/quant/market_data_mgmt/update_vanilla_config.cgi'),
        existing_config    => _get_existing_vanilla_per_symbol_config(),
        disabled           => $disabled_write,
    }) || die BOM::Backoffice::Request::template()->error;

Bar("Vanilla User Specific Limit");

BOM::Backoffice::Request::template()->process(
    'backoffice/vanilla_user_specific_limits.html.tt',
    {
        vanilla_upload_url => request()->url_for('backoffice/quant/market_data_mgmt/update_vanilla_config.cgi'),
        existing_config    => _get_existing_client_volume_limits(),
        disabled           => $disabled_write,
    }) || die BOM::Backoffice::Request::template()->error;

Bar("Vanilla Strike Price Range Markup");

BOM::Backoffice::Request::template()->process(
    'backoffice/vanilla_strike_price_range_markup.html.tt',
    {
        vanilla_upload_url => request()->url_for('backoffice/quant/market_data_mgmt/update_vanilla_config.cgi'),
        existing_config    => _get_existing_strike_price_range_markup(),
        disabled           => $disabled_write,
    }) || die BOM::Backoffice::Request::template()->error;

Bar("Vanilla Per Symbol Config (FX)");

BOM::Backoffice::Request::template()->process(
    'backoffice/vanilla_fx_per_symbol_configuration.html.tt',
    {
        vanilla_upload_url => request()->url_for('backoffice/quant/market_data_mgmt/update_vanilla_config.cgi'),
        existing_config    => _get_existing_vanilla_fx_per_symbol_config(),
        disabled           => $disabled_write,
    }) || die BOM::Backoffice::Request::template()->error;

Bar("Vanilla FX Spread on Specific Time");

BOM::Backoffice::Request::template()->process(
    'backoffice/vanilla_fx_spread_specific_time.html.tt',
    {
        vanilla_upload_url => request()->url_for('backoffice/quant/market_data_mgmt/update_vanilla_config.cgi'),
        existing_config    => _get_existing_vanilla_fx_per_symbol_config(),
        table_data         => _get_existing_vanilla_fx_spread_specific_time_config(),
        disabled           => $disabled_write,
    }) || die BOM::Backoffice::Request::template()->error;

Bar("Vanilla Financials Spread Config");

BOM::Backoffice::Request::template()->process(
    'backoffice/vanilla_spread_config.html.tt',
    {
        vanilla_upload_url => request()->url_for('backoffice/quant/market_data_mgmt/update_vanilla_config.cgi'),
        existing_config    => _get_existing_vanilla_spread_config(),
        disabled           => $disabled_write,
    }) || die BOM::Backoffice::Request::template()->error;

sub _get_existing_vanilla_commission_config {

    my $app_config = BOM::Config::Runtime->instance->app_config;

    return {
        financial     => $app_config->get('quants.vanilla.affiliate_commission.financial'),
        non_financial => $app_config->get('quants.vanilla.affiliate_commission.non_financial')};

}

sub _get_existing_strike_price_range_markup {
    my $app_config                = BOM::Config::Runtime->instance->app_config;
    my $strike_price_range_markup = decode_json_utf8($app_config->get('quants.vanilla.strike_price_range_markup'));

    my @existing;
    for my $symbol (keys $strike_price_range_markup->%*) {
        my $data = $strike_price_range_markup->{$symbol};
        for my $id (keys $data->%*) {
            my $table_data = $data->{$id};
            $table_data->{strike_price_range} = JSON::MaybeUTF8::encode_json($table_data->{strike_price_range});
            $table_data->{contract_duration}  = JSON::MaybeUTF8::encode_json($table_data->{contract_duration});
            $table_data->{id}                 = $id;
            push @existing, $table_data;
        }
    }
    return \@existing;
}

sub _get_existing_vanilla_spread_config {

    my $app_config = BOM::Config::Runtime->instance->app_config;

    my $existing = {};
    my @existing_config;

    foreach my $symbol (@symbols_financials) {
        my $key        = "quants.vanilla.fx_per_symbol_config.$symbol";
        my $all_config = decode_json_utf8($app_config->get($key));
        my $config;
        $config->{symbol}           = $symbol;
        $config->{maturities_days}  = $all_config->{maturities_allowed_days};
        $config->{maturities_weeks} = $all_config->{maturities_allowed_weeks};
        $config->{delta_config}     = $all_config->{delta_config};
        $config->{spread_spot}      = $all_config->{spread_spot};
        $config->{spread_vol}       = $all_config->{spread_vol};

        push @existing_config, $config;
    }

    return \@existing_config;
}

sub _get_existing_vanilla_maturity_config {

    my $app_config = BOM::Config::Runtime->instance->app_config;

    return {
        minimum_days => $app_config->get('quants.vanilla.maturity_config.minimum_expiry_duration_in_days'),
        maximum_days => $app_config->get('quants.vanilla.maturity_config.maximum_expiry_duration_in_days')};

}

sub _get_existing_client_volume_limits {
    my $app_config           = BOM::Config::Runtime->instance->app_config;
    my $user_specific_limits = decode_json_utf8($app_config->get('quants.vanilla.user_specific_limits'));
    my $clients              = $user_specific_limits->{clients};

    my @existing;
    for my $loginid (keys %{$clients}) {
        push @existing, $clients->{$loginid};
    }
    @existing = sort { $a->{loginid} cmp $b->{loginid} } @existing;
    return \@existing;
}

sub _get_existing_vanilla_per_symbol_config {

    my $app_config = BOM::Config::Runtime->instance->app_config;

    my @existing_config;
    my @expiry = ('intraday', 'daily');

    foreach my $symbol (@symbols_synthetics) {
        foreach my $expiry (@expiry) {
            my $key        = "quants.vanilla.per_symbol_config." . "$symbol" . "_$expiry";
            my $all_config = decode_json_utf8($app_config->get($key));
            my $config;
            $config->{symbol}                  = $symbol . "_" . $expiry;
            $config->{bs_markup}               = $all_config->{bs_markup};
            $config->{delta_config}            = encode_json_utf8($all_config->{delta_config});
            $config->{vol_markup}              = $all_config->{vol_markup};
            $config->{spread_spot}             = $all_config->{spread_spot};
            $config->{max_strike_price_choice} = $all_config->{max_strike_price_choice};
            $config->{min_number_of_contracts} = encode_json_utf8($all_config->{min_number_of_contracts});
            $config->{max_number_of_contracts} = encode_json_utf8($all_config->{max_number_of_contracts});
            $config->{max_open_position}       = $all_config->{max_open_position};
            $config->{max_daily_volume}        = $all_config->{max_daily_volume};
            $config->{max_daily_pnl}           = $all_config->{max_daily_pnl};
            $config->{risk_profile}            = $all_config->{risk_profile};
            push @existing_config, $config;
        }
    }

    return \@existing_config;
}

sub _get_existing_vanilla_fx_per_symbol_config {

    my $app_config = BOM::Config::Runtime->instance->app_config;

    my @existing_config;

    foreach my $symbol (@symbols_financials) {
        my $key        = "quants.vanilla.fx_per_symbol_config.$symbol";
        my $all_config = decode_json_utf8($app_config->get($key));
        my $config;
        $config->{symbol}                  = $symbol;
        $config->{maturities_days}         = encode_json_utf8($all_config->{maturities_allowed_days});
        $config->{maturities_weeks}        = encode_json_utf8($all_config->{maturities_allowed_weeks});
        $config->{delta_config}            = encode_json_utf8($all_config->{delta_config});
        $config->{max_strike_price_choice} = $all_config->{max_strike_price_choice};
        $config->{min_number_of_contracts} = encode_json_utf8($all_config->{min_number_of_contracts});
        $config->{max_number_of_contracts} = encode_json_utf8($all_config->{max_number_of_contracts});
        $config->{spread_spot}             = encode_json_utf8($all_config->{spread_spot});
        $config->{spread_vol}              = encode_json_utf8($all_config->{spread_vol});
        $config->{max_open_position}       = $all_config->{max_open_position};
        $config->{max_daily_volume}        = $all_config->{max_daily_volume};
        $config->{max_daily_pnl}           = $all_config->{max_daily_pnl};
        $config->{risk_profile}            = $all_config->{risk_profile};

        push @existing_config, $config;
    }

    return \@existing_config;
}

sub _get_existing_vanilla_fx_spread_specific_time_config {

    my $app_config = BOM::Config::Runtime->instance->app_config;

    my $fx_spread_specific_time = decode_json_utf8($app_config->get('quants.vanilla.fx_spread_specific_time'));

    my @table_data;
    foreach my $underlying (keys %{$fx_spread_specific_time}) {
        foreach my $delta (keys %{$fx_spread_specific_time->{$underlying}}) {
            foreach my $maturity (keys %{$fx_spread_specific_time->{$underlying}->{$delta}}) {
                foreach my $id (keys %{$fx_spread_specific_time->{$underlying}->{$delta}->{$maturity}}) {
                    my $config;
                    $config->{id}          = $id;
                    $config->{underlying}  = $underlying;
                    $config->{delta}       = $delta;
                    $config->{maturity}    = $maturity;
                    $config->{start_time}  = $fx_spread_specific_time->{$underlying}->{$delta}->{$maturity}->{$id}->{start_time};
                    $config->{end_time}    = $fx_spread_specific_time->{$underlying}->{$delta}->{$maturity}->{$id}->{end_time};
                    $config->{spread_spot} = $fx_spread_specific_time->{$underlying}->{$delta}->{$maturity}->{$id}->{spread_spot};
                    $config->{spread_vol}  = $fx_spread_specific_time->{$underlying}->{$delta}->{$maturity}->{$id}->{spread_vol};
                    push @table_data, $config;
                }
            }
        }
    }

    return \@table_data;
}

code_exit_BO();
