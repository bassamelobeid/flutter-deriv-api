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
use BOM::Database::Helper::UserSpecificLimit;
use List::MoreUtils qw(uniq);
use Scalar::Util qw(looks_like_number);
use BOM::Config::Runtime;
use BOM::Backoffice::QuantsAuditLog;
BOM::Backoffice::Sysinit::init();
my $json = JSON::MaybeXS->new;
my $args_content;
PrintContentType();
BrokerPresentation('Quants Risk Management Tool');

my $staff  = BOM::Backoffice::Auth0::get_staffname();
my $r      = request();
my $broker = $r->broker_code;

my $app_config    = BOM::Config::Runtime->instance->app_config;
my $data_in_redis = $app_config->chronicle_reader->get($app_config->setting_namespace, $app_config->setting_name);
my $old_config    = 0;
# due to app_config data_set cache, config might not be saved.
$old_config = 1 if $data_in_redis->{_rev} ne $app_config->data_set->{version};
my $quants_config    = BOM::Database::QuantsConfig->new();
my $supported_config = $quants_config->supported_config_type;

my @config_status;
foreach my $per_type (qw/per_landing_company per_user/) {
    foreach my $config_name (keys %{$supported_config->{$per_type}}) {
        my $method = 'enable_' . $config_name;
        push @config_status,
            +{
            key          => $config_name,
            display_name => $supported_config->{$per_type}{$config_name},
            status       => $app_config->quants->$method,
            };
    }
}

Bar('Quants Config Switch');

BOM::Backoffice::Request::template()->process(
    'backoffice/quants_config_switch_form.html.tt',
    {
        upload_url    => request()->url_for('backoffice/quant/update_quants_config.cgi'),
        config_status => \@config_status,
        old_config    => $old_config,
    }) || die BOM::Backoffice::Request::template()->error;

Bar('Quants Config');

my $existing_per_landing_company = BOM::Backoffice::QuantsConfigHelper::decorate_for_display($quants_config->get_all_global_limit(['default']));
my %lc_limits = map { $_ => $json->encode($existing_per_landing_company->{$_}) } keys %$existing_per_landing_company;
my $pending_market_group =
    BOM::Backoffice::QuantsConfigHelper::decorate_for_pending_market_group($quants_config->get_pending_market_group(['default']));
my %lc_pending_market_group = map { $_ => $json->encode($pending_market_group->{$_}) } keys %$pending_market_group;

my @limit_types;
foreach my $key (sort keys %$supported_config) {
    next if $key ne 'per_landing_company';
    foreach my $type (sort keys %{$supported_config->{$key}}) {
        push @limit_types, [$type, $supported_config->{$key}{$type}];
    }
}

my $output_ref               = BOM::Backoffice::QuantsConfigHelper::get_config_input('contract_group');
my $contract_groups          = [uniq map { $_->[1] } @$output_ref];
my $contract_group_data      = _format_output($output_ref);
my @existing_contract_groups = map { {key => $_, list => $contract_group_data->{$_}} } keys %$contract_group_data;

my $market_ref             = BOM::Backoffice::QuantsConfigHelper::get_config_input('market');
my $markets                = [uniq map { $_->[1] } @$market_ref];
my $market_group_data      = _format_output($market_ref);
my @existing_market_groups = map { {key => $_, list => $market_group_data->{$_}} } keys %$market_group_data;

BOM::Backoffice::Request::template()->process(
    'backoffice/quants_config_form.html.tt',
    {
        upload_url                    => request()->url_for('backoffice/quant/update_quants_config.cgi'),
        existing_landing_company      => \%lc_limits,
        existing_pending_market_group => \%lc_pending_market_group,
        existing_contract_groups      => \@existing_contract_groups,
        existing_market_groups        => \@existing_market_groups,
        data                          => {
            markets           => $json->encode([@$markets, 'new_market']),
            expiry_types      => $json->encode(BOM::Backoffice::QuantsConfigHelper::get_config_input('expiry_type')),
            contract_groups   => $json->encode([uniq(@$contract_groups)]),
            barrier_types     => $json->encode(BOM::Backoffice::QuantsConfigHelper::get_config_input('barrier_type')),
            limit_types       => \@limit_types,
            landing_companies => $json->encode(BOM::Backoffice::QuantsConfigHelper::get_config_input('landing_company')),
        },
    }) || die BOM::Backoffice::Request::template()->error;

Bar('Update Contract Group');
BOM::Backoffice::Request::template()->process(
    'backoffice/quants_contract_group_form.html.tt',
    {
        upload_url => request()->url_for('backoffice/quant/update_quants_config.cgi'),
    }) || die BOM::Backoffice::Request::template()->error;

Bar('Update Market Group');
BOM::Backoffice::Request::template()->process(
    'backoffice/quants_market_group_form.html.tt',
    {
        upload_url => request()->url_for('backoffice/quant/update_quants_config.cgi'),
    }) || die BOM::Backoffice::Request::template()->error;

my $available_global_limits = $quants_config->supported_config_type->{per_landing_company};
my %current_global_limits   = map {
    my $limit_name = $_ . '_alert_threshold';
    $_ => {
        display_key   => $available_global_limits->{$_},
        display_value => $app_config->quants->$limit_name
        }
} keys %$available_global_limits;

Bar('Update Global Limit Alert Threshold');
BOM::Backoffice::Request::template()->process(
    'backoffice/quants_global_limit_alert_threshold_form.html.tt',
    {
        upload_url => request()->url_for('backoffice/quant/update_quants_config.cgi'),
        data       => {
            global_limits  => $available_global_limits,
            current_limits => \%current_global_limits,
        },
    }) || die BOM::Backoffice::Request::template()->error;

## PRIVATE ##

sub _format_output {
    my $data = shift;

    my %groups;
    foreach my $ref (@$data) {
        my ($key, $group) = @$ref;
        unless ($groups{$group}) {
            $groups{$group} = $key;
            next;
        }
        $groups{$group} = join ', ', ($groups{$group}, $key);
    }

    return \%groups;
}

my $available_user_limits = $quants_config->supported_config_type->{per_user};
my %current_user_limits   = map {
    my $limit_name = $_ . '_alert_threshold';
    $_ => {
        display_key   => $available_user_limits->{$_},
        display_value => $app_config->quants->$limit_name
        }
} keys %$available_user_limits;

Bar('Update User Limit Alert Threshold');
BOM::Backoffice::Request::template()->process(
    'backoffice/quants_user_limit_alert_threshold_form.html.tt',
    {
        upload_url => request()->url_for('backoffice/quant/update_quants_config.cgi'),
        data       => {
            user_limits    => $available_user_limits,
            current_limits => \%current_user_limits,
        },
    }) || die BOM::Backoffice::Request::template()->error;

my $db = BOM::Database::ClientDB->new({broker_code => $broker})->db;

# Do the insert and delete here
my $update_error;
if ($r->params->{'new_user_limit'}) {
    if (not(looks_like_number($r->params->{potential_loss}) or looks_like_number($r->params->{realized_loss}))) {
        $update_error = 'Please specify either potential loss or realized loss';
    }
    if ($r->params->{market_type} !~ /^(?:financial|non_financial)$/ or $r->params->{client_type} !~ /^(?:old|new)$/) {
        $update_error = 'Market Type and Client Type are required parameters with restricted values';
    }

    BOM::Backoffice::QuantsAuditLog::log($staff, "updatenewclientlimit",
              "client_lodinid:"
            . $r->params->{'client_loginid'}
            . " potential_loss:"
            . $r->params->{'potential_loss'}
            . " realized_loss:"
            . $r->params->{'realized_loss'}
            . " client_type:"
            . $r->params->{client_type}
            . " market_type:"
            . $r->params->{market_type}
            . " expiry:"
            . $r->params->{expiry});

    BOM::Database::Helper::UserSpecificLimit->new({
            db             => $db,
            client_loginid => $r->params->{'client_loginid'},
            potential_loss => $r->params->{'potential_loss'},
            realized_loss  => $r->params->{'realized_loss'},
            client_type    => $r->params->{client_type},
            market_type    => $r->params->{market_type},
            expiry         => $r->params->{expiry},
        }
        )->record_user_specific_limit
        unless defined $update_error;
}

my $delete_error;
if ($r->params->{'delete_limit'}) {
    if ($r->params->{market_type} !~ /^(?:financial|non_financial)$/ or $r->params->{client_type} !~ /^(?:old|new)$/) {
        $delete_error = 'Market Type and Client Type are required parameters with restricted values';
    }

    $args_content = join(q{, }, map { qq{$_ => $r->params->{$_}} } keys %{$r->params});
    BOM::Backoffice::QuantsAuditLog::log($staff, "deleteclientlimit", $args_content);

    BOM::Database::Helper::UserSpecificLimit->new({
            db             => $db,
            client_loginid => $r->params->{'client_loginid'},
            client_type    => $r->params->{client_type},
            market_type    => $r->params->{market_type},
        }
        )->delete_user_specific_limit
        unless defined $delete_error;
}

my $delete_multiple_error;
if ($r->params->{'delete_multiple'}) {
    my $ids = ref($r->params->{id}) ne 'ARRAY' ? [$r->params->{id}] : $r->params->{id};

    foreach my $data (@$ids) {
        my ($client_id, $market_type, $client_type) = split '-', $data;
        my @multiple = split(' ', $client_id);

        BOM::Backoffice::QuantsAuditLog::log($staff, "deletemultipleclientlimit",
            "id" . $multiple[0] . "client_type[$client_type] market_type[$market_type]");

        BOM::Database::Helper::UserSpecificLimit->new({
                db             => $db,
                client_loginid => $multiple[0],    # first client_loginid will do
                client_type    => $client_type,
                market_type    => $market_type,
            })->delete_user_specific_limit;
    }
}

Bar("Update User Specific Limit");

my $default_user_limit = BOM::Database::Helper::UserSpecificLimit->new({
        db => $db,
    })->select_default_user_specific_limit;

BOM::Backoffice::Request::template()->process(
    'backoffice/update_user_specific_limit.html.tt',
    {
        url                => request()->url_for('backoffice/quant/quants_config.cgi'),
        default_user_limit => $default_user_limit,
        update_error       => $update_error,
        delete_error       => $delete_error,
    }) || die BOM::Backoffice::Request::template()->error;
