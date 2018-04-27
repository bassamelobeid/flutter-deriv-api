#!/etc/rmg/bin/perl

package main;

use strict;
use warnings;

use Date::Utility;
use JSON::MaybeXS;
use LandingCompany::Registry;
use f_brokerincludeall;

use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::QuantsConfigHelper;

BOM::Backoffice::Sysinit::init();
my $json = JSON::MaybeXS->new;

if (request()->param('save_limit')) {
    my %args = map { $_ => request()->param($_) }
        qw(market expiry_type contract_group underlying_symbol landing_company barrier_type limit_type limit_amount);

    print $json->encode(BOM::Backoffice::QuantsConfigHelper::save_limit(\%args));
}

if (request()->param('delete_limit')) {
    my %args =
        map { $_ => request()->param($_) } qw(market expiry_type contract_group underlying_symbol landing_company barrier_type type limit_type);
    print $json->encode(BOM::Backoffice::QuantsConfigHelper::delete_limit(\%args));
}

if (request()->param('update_contract_group')) {
    my %args = map { $_ => request()->param($_) } qw(contract_group contract_type);
    print $json->encode(BOM::Backoffice::QuantsConfigHelper::update_contract_group(\%args));
}

if (request()->param('save_threshold')) {
    my %args = map { $_ => request()->param($_) } qw(limit_type threshold_amount);
    print $json->encode(BOM::Backoffice::QuantsConfigHelper::save_threshold(\%args));
}

if (request()->param('update_config_switch')) {
    my %args = map { $_ => request()->param($_) } qw(limit_type limit_status);
    print $json->encode(BOM::Backoffice::QuantsConfigHelper::update_config_switch(\%args));
}
