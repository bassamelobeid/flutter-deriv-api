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
use BOM::Config::QuantsConfig;
use BOM::Config::Chronicle;

BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation('Accumulator Risk Management Tool');

my $disabled_write = not BOM::Backoffice::Auth0::has_quants_write_access();

Bar("Accumulator Risk Profile Definitions");
BOM::Backoffice::Request::template()->process('backoffice/accumulator_profile_definitions.html.tt', {%{_get_risk_profile_definition()},})
    || die BOM::Backoffice::Request::template()->error;

Bar("Market or Underlying symbol risk profile");
BOM::Backoffice::Request::template()->process(
    'backoffice/accumulator_market_and_underlying_risk_profile.html.tt',
    {
        accumulator_upload_url => request()->url_for('backoffice/quant/market_data_mgmt/update_accumulator_config.cgi'),
        risk_profiles          => [sort keys %{_get_default_risk_profile()}],
        %{_get_existing_market_and_symbol_risk_profile()},
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
        existing_config        => _get_existing_accumulator_per_symbol_config(),
        disabled               => $disabled_write,
    }) || die BOM::Backoffice::Request::template()->error;

Bar("Per symbol limits");
BOM::Backoffice::Request::template()->process(
    'backoffice/accumulator_per_symbol_limits.html.tt',
    {
        accumulator_upload_url => request()->url_for('backoffice/quant/market_data_mgmt/update_accumulator_config.cgi'),
        existing_config        => _get_existing_accumulator_per_symbol_limits(),
        disabled               => $disabled_write,
    }) || die BOM::Backoffice::Request::template()->error;

Bar("Account Specific Limits");
BOM::Backoffice::Request::template()->process(
    'backoffice/accumulator_user_specific_limits.html.tt',
    {
        accumulator_upload_url => request()->url_for('backoffice/quant/market_data_mgmt/update_accumulator_config.cgi'),
        existing_config        => _get_existing_user_specific_limits(),
        disabled               => $disabled_write,
    }) || die BOM::Backoffice::Request::template()->error;

sub _get_risk_profile_definition {
    my $qc = BOM::Config::QuantsConfig->new(
        contract_category => 'accumulator',
        chronicle_reader  => BOM::Config::Chronicle::get_chronicle_reader(),
    );

    my $limit_defs = _get_default_risk_profile();
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

sub _get_default_risk_profile {
    return LoadFile('/home/git/regentmarkets/bom-config/share/default_risk_profile_config.yml');
}

sub _get_existing_market_and_symbol_risk_profile {
    my $qc = BOM::Config::QuantsConfig->new(
        contract_category => 'accumulator',
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

sub _get_existing_user_specific_limits {
    my $qc = BOM::Config::QuantsConfig->new(
        contract_category => 'accumulator',
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

sub _get_existing_accumulator_commission_config {

    my $app_config = BOM::Config::Runtime->instance->app_config;

    return {
        financial     => $app_config->get('quants.accumulator.affiliate_commission.financial'),
        non_financial => $app_config->get('quants.accumulator.affiliate_commission.non_financial')};

}

sub _get_existing_accumulator_per_symbol_config {

    my $qc = BOM::Config::QuantsConfig->new(
        contract_category => 'accumulator',
        chronicle_reader  => BOM::Config::Chronicle::get_chronicle_reader(),
    );

    my $existing = [];
    #for now there's now specific config for different landing companies, so common is used.
    my @symbols = sort keys %{$qc->get_default_config('per_symbol')->{'common'}};
    foreach my $symbol (@symbols) {
        my %existing_config = %{$qc->get_per_symbol_config({underlying_symbol => $symbol, need_latest_cache => 1})};
        $existing_config{symbol}         = $symbol;
        $existing_config{'max_payout'}   = encode_json_utf8($existing_config{'max_payout'});
        $existing_config{'growth_rate'}  = encode_json_utf8($existing_config{'growth_rate'});
        $existing_config{'max_duration'} = encode_json_utf8($existing_config{'max_duration'});

        push @{$existing}, \%existing_config;
    }

    return $existing;
}

sub _get_existing_accumulator_per_symbol_limits {

    my $qc = BOM::Config::QuantsConfig->new(
        contract_category => 'accumulator',
        chronicle_reader  => BOM::Config::Chronicle::get_chronicle_reader(),
    );

    my $existing = [];

    #for now there's now specific config for different landing companies, so common is used.
    my @symbols = sort keys %{$qc->get_default_config('per_symbol_limits')->{'common'}};
    foreach my $symbol (@symbols) {
        my %existing_config = %{$qc->get_per_symbol_limits({underlying_symbol => $symbol})};
        $existing_config{symbol}                     = $symbol;
        $existing_config{'max_aggregate_open_stake'} = encode_json_utf8($existing_config{'max_aggregate_open_stake'});
        push @{$existing}, \%existing_config;
    }

    return $existing;
}

code_exit_BO();
