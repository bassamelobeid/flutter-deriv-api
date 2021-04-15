#!/etc/rmg/bin/perl

package main;

use strict;
use warnings;
use JSON::MaybeUTF8 qw(:v1);
use BOM::Config::Runtime;
use BOM::Database::Helper::UserSpecificLimit;
use BOM::Database::ClientDB;
use BOM::User::Client;
use BOM::Config;
use BOM::Backoffice::Sysinit ();
use BOM::Config::Chronicle;

BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation('Multiplier Risk Management Tool');

Bar("Multiplier Risk Profile Definitions");

my $limit_defs = BOM::Config::quants()->{risk_profile};
my @currencies = sort keys %{$limit_defs->{no_business}{multiplier}};
my @stake_rows;
for my $key (sort keys %{$limit_defs}) {
    push @stake_rows, [$key, @{$limit_defs->{$key}{multiplier}}{@currencies}];
}

my $disabled_write = not BOM::Backoffice::Auth0::has_quants_write_access();
BOM::Backoffice::Request::template()->process(
    'backoffice/multiplier_profile_definitions.html.tt',
    {
        currencies  => \@currencies,
        stake_rows  => \@stake_rows,
        definitions => $limit_defs,
    }) || die BOM::Backoffice::Request::template()->error;

Bar("Multiplier Affiliate Commission");

BOM::Backoffice::Request::template()->process(
    'backoffice/multiplier_affiliate_commission.html.tt',
    {
        multiplier_upload_url => request()->url_for('backoffice/quant/market_data_mgmt/update_multiplier_config.cgi'),
        existing_config       => _get_existing_commission_config(),
        disabled              => $disabled_write,
    }) || die BOM::Backoffice::Request::template()->error;

Bar("Per symbol configuration");

BOM::Backoffice::Request::template()->process(
    'backoffice/multiplier_per_symbol_configuration.html.tt',
    {
        multiplier_upload_url => request()->url_for('backoffice/quant/market_data_mgmt/update_multiplier_config.cgi'),
        existing_config       => _get_existing_multiplier_config(),
        disabled              => $disabled_write,
    }) || die BOM::Backoffice::Request::template()->error;

Bar("Market or Underlying symbol limits");

BOM::Backoffice::Request::template()->process(
    'backoffice/multiplier_market_and_underlying_limits.html.tt',
    {
        multiplier_upload_url => request()->url_for('backoffice/quant/market_data_mgmt/update_multiplier_config.cgi'),
        risk_profiles         => [sort keys %{BOM::Config::quants()->{risk_profile}}],
        %{_get_existing_market_and_symbol_volume_limits()},
    }) || die BOM::Backoffice::Request::template()->error;

Bar("User specific limits");

BOM::Backoffice::Request::template()->process(
    'backoffice/multiplier_user_specific_limits.html.tt',
    {
        existing_volume_limits => _get_existing_client_volume_limits(),
        multiplier_upload_url  => request()->url_for('backoffice/quant/market_data_mgmt/update_multiplier_config.cgi'),
    }) || die BOM::Backoffice::Request::template()->error;

Bar("Custom multiplier commissions");

my $existing_custom_multiplier_config = _get_existing_custom_multiplier_commissions();

BOM::Backoffice::Request::template()->process(
    'backoffice/multiplier_custom_commissions.html.tt',
    {
        multiplier_upload_url                  => request()->url_for('backoffice/quant/market_data_mgmt/update_multiplier_config.cgi'),
        existing_custom_multiplier_commissions => encode_json_utf8($existing_custom_multiplier_config),
        disabled                               => $disabled_write,
    }) || die BOM::Backoffice::Request::template()->error;

sub _get_existing_commission_config {

    my $app_config = BOM::Config::Runtime->instance->app_config;

    return {
        financial     => $app_config->get('quants.multiplier_affiliate_commission.financial'),
        non_financial => $app_config->get('quants.multiplier_affiliate_commission.non_financial')};

}

sub _get_existing_multiplier_config {
    my $qc               = BOM::Config::QuantsConfig->new(chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader());
    my $all_config       = $qc->get_multiplier_config_default();
    my %display_priority = (
        synthetic_index => 0,
        forex           => 1,
        cryptocurrency  => 2,
    );

    my %existing;
    foreach my $category (keys %$all_config) {
        $existing{$category}->{selected} = $category eq 'common' ? 1 : 0;
        # the idea is to group by market and also sort by underlying symbol in a market group
        foreach my $u (
            sort { $display_priority{$a->market->name} <=> $display_priority{$b->market->name} }
            map  { create_underlying($_) } sort keys %{$all_config->{$category}})
        {
            my $config = $qc->get_multiplier_config($category, $u->symbol);
            $config->{multiplier_range_json}            = encode_json_utf8($config->{multiplier_range});
            $config->{cancellation_duration_range_json} = encode_json_utf8($config->{cancellation_duration_range});
            $config->{stop_out_level_json}              = encode_json_utf8($config->{stop_out_level});
            $config->{symbol}                           = $u->symbol;
            push @{$existing{$category}->{items}}, $config;
        }
    }

    return \%existing;
}

sub _get_existing_custom_multiplier_commissions {
    my $qc         = BOM::Config::QuantsConfig->new(chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader());
    my $all_config = $qc->get_config('custom_multiplier_commission') // [];

    foreach my $config (@{$all_config}) {
        $config->{start_time} = Date::Utility->new($config->{start_time})->datetime;
        $config->{end_time}   = Date::Utility->new($config->{end_time})->datetime;
    }

    return $all_config;
}

sub _get_existing_client_volume_limits {
    my $app_config           = BOM::Config::Runtime->instance->app_config;
    my $custom_volume_limits = decode_json_utf8($app_config->get('quants.custom_volume_limits'));
    my $clients              = $custom_volume_limits->{clients};

    my @existing;
    for my $loginid (keys %{$clients}) {
        for my $unique_key (keys %{$clients->{$loginid}}) {
            push @existing, $clients->{$loginid}{$unique_key};
        }
    }
    @existing = sort { $a->{loginid} . $a->{uniq_key} cmp $b->{loginid} . $b->{uniq_key} } @existing;
    return \@existing;
}

sub _get_existing_market_and_symbol_volume_limits {
    my $app_config           = BOM::Config::Runtime->instance->app_config;
    my $custom_volume_limits = decode_json_utf8($app_config->get('quants.custom_volume_limits'));
    my $markets              = $custom_volume_limits->{markets};
    my $symbols              = $custom_volume_limits->{symbols};

    my @market_limits;
    my @symbol_limits;

    for my $market (sort keys %{$markets}) {
        push @market_limits, {%{$markets->{$market}}, market => $market};
    }
    for my $symbol (sort keys %{$symbols}) {
        push @symbol_limits, {%{$symbols->{$symbol}}, symbol => $symbol};
    }

    my $offerings = LandingCompany::Registry::get('virtual')->basic_offerings(BOM::Config::Runtime->instance->get_offerings_config);

    my @market_limits_default;
    foreach my $market ($offerings->query({contract_category => 'multiplier'}, ['market'])) {
        push @market_limits_default,
            {
            market               => $market,
            max_volume_positions => 5,
            risk_profile         => Finance::Asset::Market::Registry->instance->get($market)->{risk_profile}};
    }

    return {
        market_limits_default => \@market_limits_default,
        market_limits         => \@market_limits,
        symbol_limits         => \@symbol_limits
    };
}

code_exit_BO();
