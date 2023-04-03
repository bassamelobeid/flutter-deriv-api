#!/etc/rmg/bin/perl

package main;

use strict;
use warnings;
use JSON::MaybeUTF8 qw(:v1);
use YAML::XS        qw(LoadFile);
use List::Util      qw(min max);

use BOM::Config::Runtime;
use BOM::Backoffice::Sysinit ();
use LandingCompany::Registry;

BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation('Vanilla Risk Management Tool');

my $disabled_write = not BOM::Backoffice::Auth0::has_quants_write_access();

my $limit_defs = BOM::Config::quants()->{risk_profile};
my @currencies = sort keys %{$limit_defs->{no_business}{multiplier}};
my @stake_rows;

my $app_config = BOM::Config::Runtime->instance->app_config;

foreach my $risk_level (keys %$limit_defs) {
    my $s = decode_json_utf8($app_config->get("quants.vanilla.risk_profile.$risk_level"));
    my @stake;
    foreach my $ccy (sort keys %{$s}) {
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

sub _get_existing_vanilla_commission_config {

    my $app_config = BOM::Config::Runtime->instance->app_config;

    return {
        financial     => $app_config->get('quants.vanilla.affiliate_commission.financial'),
        non_financial => $app_config->get('quants.vanilla.affiliate_commission.non_financial')};

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

    my $now      = time;
    my $existing = {};
    my @existing_config;
    my $selected         = 0;
    my $offerings_config = {
        action          => 'buy',
        loaded_revision => 0,
    };
    my @expiry = ('intraday', 'daily');

    my $offerings = LandingCompany::Registry->by_name('virtual')->basic_offerings($offerings_config);
    my @symbols   = sort $offerings->query({contract_category => 'vanilla'}, ['underlying_symbol']);
    foreach my $symbol (@symbols) {
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

code_exit_BO();
