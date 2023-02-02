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
BrokerPresentation('Accumulator Risk Management Tool');

my $disabled_write = not BOM::Backoffice::Auth0::has_quants_write_access();

Bar("Accumulator Risk Profile Definitions");
my $limit_defs = BOM::Config::quants()->{risk_profile};
my @currencies = sort keys %{$limit_defs->{no_business}{accumulator}};
my @stake_rows;
foreach my $key (sort keys %{$limit_defs}) {
    push @stake_rows, [$key, @{$limit_defs->{$key}{accumulator}}{@currencies}];
}
BOM::Backoffice::Request::template()->process(
    'backoffice/accumulator_profile_definitions.html.tt',
    {
        currencies  => \@currencies,
        stake_rows  => \@stake_rows,
        definitions => $limit_defs,
    }) || die BOM::Backoffice::Request::template()->error;

Bar("Market or Underlying symbol risk profile");
BOM::Backoffice::Request::template()->process(
    'backoffice/accumulator_market_and_underlying_risk_profile.html.tt',
    {
        accumulator_upload_url => request()->url_for('backoffice/quant/market_data_mgmt/update_accumulator_config.cgi'),
        risk_profiles          => [sort keys %{BOM::Config::quants()->{risk_profile}}],
        %{_get_existing_market_and_symbol_volume_risk_profile()},
    }) || die BOM::Backoffice::Request::template()->error;

Bar("Accumulator Affiliate Commission");
BOM::Backoffice::Request::template()->process(
    'backoffice/accumulator_affiliate_commission.html.tt',
    {
        accumulator_upload_url => request()->url_for('backoffice/quant/market_data_mgmt/update_accumulator_config.cgi'),
        existing_config        => _get_existing_accumulator_commission_config(),
        disabled               => $disabled_write,
    }) || die BOM::Backoffice::Request::template()->error;

Bar("Per symbol configuration");
BOM::Backoffice::Request::template()->process(
    'backoffice/accumulator_per_symbol_configuration.html.tt',
    {
        accumulator_upload_url => request()->url_for('backoffice/quant/market_data_mgmt/update_accumulator_config.cgi'),
        existing_config        => _get_existing_accumulator_config(),
        disabled               => $disabled_write,
    }) || die BOM::Backoffice::Request::template()->error;

Bar("Accumulator Client Limits");
BOM::Backoffice::Request::template()->process(
    'backoffice/accumulator_client_limits.html.tt',
    {
        accumulator_upload_url => request()->url_for('backoffice/quant/market_data_mgmt/update_accumulator_config.cgi'),
        existing_config        => _get_existing_accumulator_client_limits_config(),
        disabled               => $disabled_write,
    }) || die BOM::Backoffice::Request::template()->error;

sub _get_existing_market_and_symbol_volume_risk_profile {
    my $app_config = BOM::Config::Runtime->instance->app_config;
    my $markets    = decode_json_utf8($app_config->get('quants.accumulator.risk_profile.market'));
    my $symbols    = decode_json_utf8($app_config->get('quants.accumulator.risk_profile.symbol'));

    my @market_risk_profiles;
    my @symbol_risk_profiles;

    foreach my $market (sort keys %{$markets}) {
        push @market_risk_profiles,
            {
            market       => $market,
            risk_profile => $markets->{$market}};
    }
    foreach my $symbol (sort keys %{$symbols}) {
        push @symbol_risk_profiles,
            {
            symbol       => $symbol,
            risk_profile => $symbols->{$symbol}};
    }

    my $offerings = LandingCompany::Registry->by_name('virtual')->basic_offerings(BOM::Config::Runtime->instance->get_offerings_config);

    my @market_risk_profile_default;
    foreach my $market ($offerings->query({contract_category => 'accumulator'}, ['market'])) {
        my $market_obj = Finance::Underlying::Market::Registry->instance->get($market);
        next unless $market_obj;
        push @market_risk_profile_default,
            {
            market       => $market,
            risk_profile => $market_obj->{risk_profile}};
    }

    return {
        market_risk_profile_default => \@market_risk_profile_default,
        market_risk_profiles        => \@market_risk_profiles,
        symbol_risk_profiles        => \@symbol_risk_profiles
    };
}

sub _get_existing_accumulator_commission_config {

    my $app_config = BOM::Config::Runtime->instance->app_config;

    return {
        financial     => $app_config->get('quants.accumulator.affiliate_commission.financial'),
        non_financial => $app_config->get('quants.accumulator.affiliate_commission.non_financial')};

}

sub _get_existing_accumulator_config {

    my $app_config        = BOM::Config::Runtime->instance->app_config;
    my @landing_companies = ('svg', 'virtual');
    my $now               = time;
    my $existing          = {};
    my $selected          = 0;
    my $offerings_config  = {
        action          => 'buy',
        loaded_revision => 0,
    };

    foreach my $lc (@landing_companies) {
        my $offerings = LandingCompany::Registry->by_name($lc)->basic_offerings($offerings_config);
        my @symbols   = sort $offerings->query({contract_category => 'accumulator'}, ['underlying_symbol']);
        foreach my $symbol (@symbols) {
            my $all_config      = decode_json_utf8($app_config->get("quants.accumulator.symbol_config.$lc.$symbol"));
            my $latest_key      = max grep { $_ <= $now } keys %{$all_config};
            my $existing_config = $all_config->{$latest_key};
            $existing_config->{'symbol_name'} = $symbol;
            $existing_config->{'max_payout'}  = encode_json_utf8($existing_config->{'max_payout'});
            $existing_config->{'growth_rate'} = encode_json_utf8($existing_config->{'growth_rate'});
            push @{$existing->{$lc}->{items}}, $existing_config;
        }
        $existing->{$lc}->{'selected'} = $selected;
        $selected++;
    }

    return $existing;
}

sub _get_existing_accumulator_client_limits_config {

    my $app_config = BOM::Config::Runtime->instance->app_config;

    return {

        max_open_positions => $app_config->get('quants.accumulator.client_limits.max_open_positions'),
        max_daily_volume   => $app_config->get('quants.accumulator.client_limits.max_daily_volume')};

}

code_exit_BO();
