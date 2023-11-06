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
BrokerPresentation('Turbos Risk Management Tool');

my $disabled_write = not BOM::Backoffice::Auth::has_quants_write_access();

Bar("Risk Profile Definitions");
BOM::Backoffice::Request::template()->process('backoffice/turbos_profile_definitions.html.tt', {%{_get_turbos_risk_profile_definition()}},)
    || die BOM::Backoffice::Request::template()->error;

sub _get_turbos_risk_profile_definition {
    my $qc = BOM::Config::QuantsConfig->new(
        contract_category => 'turbos',
        chronicle_reader  => BOM::Config::Chronicle::get_chronicle_reader(),
    );

    my $limit_defs = _get_default_risk_profile_turbos();
    my @currencies = sort keys %{$limit_defs->{low_risk}};
    my @stake_rows;

    foreach my $risk_level (keys %$limit_defs) {
        my $max_stake = $qc->get_max_stake_per_risk_profile($risk_level);
        my @stake;
        foreach my $currency (sort keys %{$max_stake}) {
            push @stake, $max_stake->{$currency};
        }

        push @stake_rows, [$risk_level, @stake];
    }

    return {
        currencies  => \@currencies,
        stake_rows  => \@stake_rows,
        definitions => $limit_defs,
    };
}

sub _get_default_risk_profile_turbos {
    return LoadFile('/home/git/regentmarkets/bom-config/share/default_risk_profile_config.yml');
}

Bar("Market or Underlying symbol risk profile");
BOM::Backoffice::Request::template()->process(
    'backoffice/turbos_market_and_underlying_risk_profile.html.tt',
    {
        turbos_upload_url => request()->url_for('backoffice/quant/market_data_mgmt/update_turbos_config.cgi'),
        risk_profiles     => [sort keys %{_get_default_risk_profile_turbos()}],
        %{_get_existing_market_and_symbol_risk_profile_turbos()},
    }) || die BOM::Backoffice::Request::template()->error;

sub _get_existing_market_and_symbol_risk_profile_turbos {
    my $qc = BOM::Config::QuantsConfig->new(
        contract_category => 'turbos',
        chronicle_reader  => BOM::Config::Chronicle::get_chronicle_reader(),
    );
    my $markets = $qc->get_risk_profile_per_market // {};
    my $symbols = $qc->get_risk_profile_per_symbol // {};

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
    foreach my $market ($offerings->query({contract_category => 'turbos'}, ['market'])) {
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

Bar("Affiliate Commission");

BOM::Backoffice::Request::template()->process(
    'backoffice/turbos_affiliate_commission.html.tt',
    {
        turbos_upload_url => request()->url_for('backoffice/quant/market_data_mgmt/update_turbos_config.cgi'),
        existing_config   => _get_existing_turbos_commission_config(),
        disabled          => $disabled_write,
    }) || die BOM::Backoffice::Request::template()->error;

sub _get_existing_turbos_commission_config {
    my $app_config = BOM::Config::Runtime->instance->app_config;
    return {
        financial     => $app_config->get('quants.turbos.affiliate_commission.financial'),
        non_financial => $app_config->get('quants.turbos.affiliate_commission.non_financial')};

}

Bar("Per Symbol Config");

BOM::Backoffice::Request::template()->process(
    'backoffice/turbos_per_symbol_config.html.tt',
    {
        turbos_upload_url => request()->url_for('backoffice/quant/market_data_mgmt/update_turbos_config.cgi'),
        existing_config   => _get_per_symbol_config(),
        disabled          => $disabled_write,
    }) || die BOM::Backoffice::Request::template()->error;

sub _get_per_symbol_config {

    my $qc = BOM::Config::QuantsConfig->new(
        contract_category => 'turbos',
        chronicle_reader  => BOM::Config::Chronicle::get_chronicle_reader(),
    );
    my $default_barrier_config = $qc->get_default_config('per_symbol');
    my $existing               = [];
    my $latest_cache           = 'true';
    my $lc                     = 'common';
    my @symbols                = sort keys %{$default_barrier_config->{$lc}};

    foreach my $symbol (@symbols) {
        my %existing_config = %{$qc->get_per_symbol_config({underlying_symbol => $symbol, need_latest_cache => $latest_cache})};
        $existing_config{symbol}                 = $symbol;
        $existing_config{'max_multiplier_stake'} = encode_json_utf8($existing_config{'max_multiplier_stake'});
        $existing_config{'min_multiplier_stake'} = encode_json_utf8($existing_config{'min_multiplier_stake'});
        push @{$existing}, \%existing_config;
    }

    return $existing;
}

Bar("User Specific Limit");

BOM::Backoffice::Request::template()->process(
    'backoffice/turbos_user_specific_limits.html.tt',
    {
        turbos_upload_url => request()->url_for('backoffice/quant/market_data_mgmt/update_turbos_config.cgi'),
        existing_config   => _get_existing_user_specific_limits_turbos(),
        disabled          => $disabled_write,
    }) || die BOM::Backoffice::Request::template()->error;

sub _get_existing_user_specific_limits_turbos {
    my $qc = BOM::Config::QuantsConfig->new(
        contract_category => 'turbos',
        chronicle_reader  => BOM::Config::Chronicle::get_chronicle_reader());

    my $user_specific_limits = $qc->get_user_specific_limits // {};

    my $clients = $user_specific_limits->{clients};

    my @existing;
    for my $loginid (keys %{$clients}) {
        push @existing, $clients->{$loginid};
    }
    @existing = sort { $a->{loginid} cmp $b->{loginid} } @existing;
    return \@existing;
}

code_exit_BO();
