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

my $disabled_write = not BOM::Backoffice::Auth0::has_quants_write_access();

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

    my $default_barrier_config = $qc->get_config_default('per_symbol');
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
        existing_config   => _get_existing_user_specific_limits(),
        disabled          => $disabled_write,
    }) || die BOM::Backoffice::Request::template()->error;

sub _get_existing_user_specific_limits {
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
