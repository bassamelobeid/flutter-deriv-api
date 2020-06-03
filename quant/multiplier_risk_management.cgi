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

sub _get_existing_multiplier_config {
    my $qc = BOM::Config::QuantsConfig->new(chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader());
    my $offerings = LandingCompany::Registry::get('virtual')->basic_offerings(BOM::Config::Runtime->instance->get_offerings_config);

    my @existing;
    foreach my $market ($offerings->query({contract_category => 'multiplier'}, ['market'])) {
        foreach my $symbol (
            $offerings->query({
                    contract_category => 'multiplier',
                    market            => $market
                },
                ['underlying_symbol']))
        {
            my $config = $qc->get_config('multiplier_config::' . $symbol);
            $config->{multiplier_range_json} = encode_json_utf8($config->{multiplier_range}) unless $config->{multiplier_range_json};
            $config->{cancellation_duration_range_json} = encode_json_utf8($config->{cancellation_duration_range})
                unless $config->{cancellation_duration_range_json};
            $config->{symbol} = $symbol;
            push @existing, $config;

        }
    }
    return \@existing;
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

    my $qc = BOM::Config::QuantsConfig->new(chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader());
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

