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

sub _get_existing_accumulator_commission_config {

    my $app_config = BOM::Config::Runtime->instance->app_config;

    return {
        financial     => $app_config->get('quants.accumulator.affiliate_commission.financial'),
        non_financial => $app_config->get('quants.accumulator.affiliate_commission.non_financial')};

}

sub _get_existing_accumulator_config {

    my $app_config = BOM::Config::Runtime->instance->app_config;

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

code_exit_BO();
