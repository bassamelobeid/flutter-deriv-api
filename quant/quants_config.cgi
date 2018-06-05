#!/etc/rmg/bin/perl

package main;

use strict;
use warnings;

use Date::Utility;
use JSON::MaybeXS;
use LandingCompany::Registry;
use f_brokerincludeall;

use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::QuantsConfigHelper;
use BOM::Database::QuantsConfig;
use BOM::Config::Chronicle;
use BOM::Database::ClientDB;
use List::MoreUtils qw(uniq);
use BOM::Config::Runtime;

BOM::Backoffice::Sysinit::init();
my $json = JSON::MaybeXS->new;

PrintContentType();
BrokerPresentation('Quants Risk Management Tool');

my $staff = BOM::Backoffice::Auth0::from_cookie()->{nickname};
my $r     = request();

my $app_config    = BOM::Config::Runtime->instance->app_config;
my $data_in_redis = $app_config->chronicle_reader->get($app_config->setting_namespace, $app_config->setting_name);
my $old_config    = 0;
# due to app_config data_set cache, config might not be saved.
$old_config = 1 if $data_in_redis->{_rev} ne $app_config->data_set->{version};
my $quants_config    = BOM::Database::QuantsConfig->new();
my $supported_config = $quants_config->supported_config_type;

my @config_status;
foreach my $config_name (keys %{$supported_config->{per_landing_company}}) {
    my $method = 'enable_' . $config_name;
    push @config_status,
        +{
        key          => $config_name,
        display_name => $supported_config->{per_landing_company}{$config_name},
        status       => $app_config->quants->$method,
        };
}

Bar('Quants Config Switch');

BOM::Backoffice::Request::template->process(
    'backoffice/quants_config_switch_form.html.tt',
    {
        upload_url    => request()->url_for('backoffice/quant/update_quants_config.cgi'),
        config_status => \@config_status,
        old_config    => $old_config,
    }) || die BOM::Backoffice::Request::template->error;

Bar('Quants Config');

my $existing_per_landing_company = BOM::Backoffice::QuantsConfigHelper::decorate_for_display($quants_config->get_all_global_limit(['default']));
my %lc_limits = map { $_ => $json->encode($existing_per_landing_company->{$_}) } keys %$existing_per_landing_company;

my @limit_types;
foreach my $key (keys %$supported_config) {
    foreach my $type (keys %{$supported_config->{$key}}) {
        push @limit_types, [$type, $supported_config->{$key}{$type}];
    }
}

my $output_ref = BOM::Backoffice::QuantsConfigHelper::get_config_input('contract_group');
my $contract_groups = [uniq map { $_->[1] } @$output_ref];
my %group;
foreach my $ref (@$output_ref) {
    my ($contract_type, $contract_group) = @$ref;
    unless ($group{$contract_group}) {
        $group{$contract_group} = $contract_type;
        next;
    }
    $group{$contract_group} = join ',', ($group{$contract_group}, $contract_type);
}

my @existing_contract_groups = map { {key => $_, list => $group{$_}} } keys %group;

BOM::Backoffice::Request::template->process(
    'backoffice/quants_config_form.html.tt',
    {
        upload_url               => request()->url_for('backoffice/quant/update_quants_config.cgi'),
        existing_landing_company => \%lc_limits,
        existing_contract_groups => \@existing_contract_groups,
        data                     => {
            markets           => $json->encode(BOM::Backoffice::QuantsConfigHelper::get_config_input('market')),
            expiry_types      => $json->encode(BOM::Backoffice::QuantsConfigHelper::get_config_input('expiry_type')),
            contract_groups   => $json->encode([uniq(@$contract_groups, 'new_category')]),
            barrier_types     => $json->encode(BOM::Backoffice::QuantsConfigHelper::get_config_input('barrier_type')),
            limit_types       => \@limit_types,
            landing_companies => $json->encode(BOM::Backoffice::QuantsConfigHelper::get_config_input('landing_company')),
        },
    }) || die BOM::Backoffice::Request::template->error;

Bar('Update Contract Group');
BOM::Backoffice::Request::template->process(
    'backoffice/quants_contract_group_form.html.tt',
    {
        upload_url => request()->url_for('backoffice/quant/update_quants_config.cgi'),
    }) || die BOM::Backoffice::Request::template->error;

my $available_global_limits = $quants_config->supported_config_type->{per_landing_company};
my %current_global_limits   = map {
    my $limit_name = $_ . '_alert_threshold';
    $_ => {
        display_key   => $available_global_limits->{$_},
        display_value => $app_config->quants->$limit_name
        }
} keys %$available_global_limits;

Bar('Update Global Limit Alert Threshold');
BOM::Backoffice::Request::template->process(
    'backoffice/quants_global_limit_alert_threshold_form.html.tt',
    {
        upload_url => request()->url_for('backoffice/quant/update_quants_config.cgi'),
        data       => {
            global_limits  => $available_global_limits,
            current_limits => \%current_global_limits,
        },
    }) || die BOM::Backoffice::Request::template->error;

