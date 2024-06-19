#!/etc/rmg/bin/perl

package main;

use strict;
use warnings;

use Date::Utility;
use JSON::MaybeXS;
use f_brokerincludeall;
use Text::Trim qw(trim);

use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request      qw(request);
use BOM::Backoffice::Sysinit      ();
use BOM::Backoffice::QuantsConfigHelper;
use BOM::Database::QuantsConfig;
use BOM::Config::Chronicle;
use BOM::Database::ClientDB;
use BOM::Database::Helper::UserSpecificLimit;
use List::MoreUtils qw(uniq);
use Scalar::Util    qw(looks_like_number);
use BOM::Config::Runtime;
use BOM::Backoffice::QuantsAuditLog;
use Time::Duration::Concise;
use Finance::Underlying::Market::Registry;
use BOM::Config::Redis;

BOM::Backoffice::Sysinit::init();

my $json = JSON::MaybeXS->new;
my $args_content;
PrintContentType();
BrokerPresentation('Quants Risk Management Tool');

my $staff  = BOM::Backoffice::Auth::get_staffname();
my $r      = request();
my $broker = $r->broker_code;

my $app_config    = BOM::Config::Runtime->instance->app_config;
my $data_in_redis = $app_config->chronicle_reader->get($app_config->setting_namespace, $app_config->setting_name);
my $old_config    = 0;
# due to app_config data_set cache, config might not be saved.
$old_config = 1 if ($data_in_redis->{_rev} // '') ne ($app_config->data_set->{version} // '');
my $quants_config    = BOM::Database::QuantsConfig->new();
my $supported_config = $quants_config->supported_config_type;
my @config_status    = BOM::Backoffice::QuantsConfigHelper::get_global_config_status();

my $disabled_write = not BOM::Backoffice::Auth::has_quants_write_access();

Bar('Quants Config Switch');

BOM::Backoffice::Request::template()->process(
    'backoffice/quants_config_switch_form.html.tt',
    {
        upload_url    => request()->url_for('backoffice/quant/update_quants_config.cgi'),
        config_status => \@config_status,
        old_config    => $old_config,
        disabled      => $disabled_write,
    }) || die BOM::Backoffice::Request::template()->error;

Bar('Quants Config');

=head2 _compare_values

Comparing values between $global_limit_hit and $all_global_limits

=cut

sub _compare_values {
    my ($global_limit_hit, $global_limit) = @_;
    my @keys_to_check = qw (market contract_group expiry_type);
    my $check         = 0;
    for my $key (@keys_to_check) {
        $check = $global_limit_hit->{rank}{$key} eq $global_limit->{$key} ? 1 : 0;
        if ($check == 0) {
            return 0;
        }
    }
    return $check;
}

# Reading global::limits from redis hash
my $redis_key             = "global::limits";
my $redis                 = BOM::Config::Redis::redis_replicated_read();
my $global_limits_hit_ref = $redis->hvals($redis_key);
my $all_global_limits_ref = $quants_config->get_all_global_limit(['default']);
my @limits_crossed        = ();

for my $global_limit (@$all_global_limits_ref) {
    for my $limit_hit (@$global_limits_hit_ref) {

        # dereferencing
        my $global_limits_hit = $json->decode($limit_hit);

        # replacing undef values with 'default'
        $global_limits_hit->{rank}{contract_group} //= "default";
        $global_limits_hit->{rank}{market}         //= "default";
        $global_limits_hit->{rank}{expiry_type}    //= "default";
        $global_limits_hit->{rank}{is_atm}         //= "default";
        my $global_loss_limit =
            $global_limit->{global_realized_loss} ? $global_limit->{global_realized_loss} : $global_limit->{global_potential_loss};

        # comparison of global_limits_hit from redis hash and $global_limit from the $quants_config->get_all_global_limit
        if (_compare_values($global_limits_hit, $global_limit)
            && $global_limits_hit->{current_amount} >= $global_loss_limit)
        {
            if ($global_limits_hit->{landing_company_short} && $global_limits_hit->{landing_company_short} eq $global_limit->{landing_company}) {
                # replacing landing company short name with their respective broker code i.e. svg to cr01;
                $global_limit->{landing_company} = $global_limits_hit->{landing_company};
                push(@limits_crossed, $global_limit);
            }

        }
    }
}

my $existing_per_landing_company = BOM::Backoffice::QuantsConfigHelper::decorate_for_display($quants_config->get_all_global_limit(['default']));
my %lc_limits                    = map { $_ => $json->encode($existing_per_landing_company->{$_}) } keys %$existing_per_landing_company;
my $global_realized_limits       = BOM::Backoffice::QuantsConfigHelper::decorate_for_display(\@limits_crossed);
my %global_realized_limits_data  = map { $_ => $json->encode($global_realized_limits->{$_}) } keys %$global_realized_limits;
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

my $market_ref        = BOM::Backoffice::QuantsConfigHelper::get_config_input('market');
my $markets           = [uniq map { $_->[1] } @$market_ref];
my $market_group_data = _format_output($market_ref);
my @existing_market_groups =
    map { {key => Finance::Underlying::Market::Registry->get($_)->display_name, list => $market_group_data->{$_}} } keys %$market_group_data;

my @underlying_symbols = ();
foreach my $values (@existing_market_groups) {
    my @split_sub_array = split(", ", $values->{list});
    push @underlying_symbols, @split_sub_array;
}

BOM::Backoffice::Request::template()->process(
    'backoffice/quants_config_form.html.tt',
    {
        upload_url                    => request()->url_for('backoffice/quant/update_quants_config.cgi'),
        existing_landing_company      => \%lc_limits,
        global_limits_passed          => \%global_realized_limits_data,
        existing_pending_market_group => \%lc_pending_market_group,
        existing_contract_groups      => \@existing_contract_groups,
        existing_market_groups        => \@existing_market_groups,
        underlying_symbols            => $json->encode(\@underlying_symbols),
        data                          => {
            markets => $json->encode([
                    (map { {value => $_, display_value => Finance::Underlying::Market::Registry->get($_)->display_name} } @$markets),
                    {
                        value         => 'new_market',
                        display_value => 'New Market'
                    }]
            ),
            expiry_types      => $json->encode(BOM::Backoffice::QuantsConfigHelper::get_config_input('expiry_type')),
            contract_groups   => $json->encode([uniq(@$contract_groups)]),
            barrier_types     => $json->encode(BOM::Backoffice::QuantsConfigHelper::get_config_input('barrier_type')),
            limit_types       => \@limit_types,
            landing_companies => $json->encode(BOM::Backoffice::QuantsConfigHelper::get_config_input('landing_company')),
        },
        disabled => $disabled_write,
    }) || die BOM::Backoffice::Request::template()->error;

my $available_user_limits = $quants_config->supported_config_type->{per_user};
my %current_user_limits   = map {
    my $limit_name = $_ . '_alert_threshold';
    $_ => {
        display_key   => $available_user_limits->{$_},
        display_value => $app_config->quants->$limit_name
    }
} keys %$available_user_limits;

Bar('Update ultra short duration');
BOM::Backoffice::Request::template()->process(
    'backoffice/quants_update_ultra_short_form.html.tt',
    {
        upload_url => request()->url_for('backoffice/quant/update_quants_config.cgi'),
        data       => {
            duration => Time::Duration::Concise->new(interval => $app_config->quants->ultra_short_duration)->as_string(),
        },
        disabled => $disabled_write,
    }) || die BOM::Backoffice::Request::template()->error;

Bar('Update Contract Group');
BOM::Backoffice::Request::template()->process(
    'backoffice/quants_contract_group_form.html.tt',
    {
        upload_url => request()->url_for('backoffice/quant/update_quants_config.cgi'),
        disabled   => $disabled_write,
    }) || die BOM::Backoffice::Request::template()->error;

Bar('Update Market Group');
BOM::Backoffice::Request::template()->process(
    'backoffice/quants_market_group_form.html.tt',
    {
        upload_url => request()->url_for('backoffice/quant/update_quants_config.cgi'),
        disabled   => $disabled_write,
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
        disabled => $disabled_write,
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

Bar('Update User Limit Alert Threshold');
BOM::Backoffice::Request::template()->process(
    'backoffice/quants_user_limit_alert_threshold_form.html.tt',
    {
        upload_url => request()->url_for('backoffice/quant/update_quants_config.cgi'),
        data       => {
            user_limits    => $available_user_limits,
            current_limits => \%current_user_limits,
        },
        disabled => $disabled_write,
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
    $update_error = "permission denied: no write access" if $disabled_write;

    my @clients = split(/\s+/, $r->params->{'client_loginid'});

    foreach my $client (@clients) {

        BOM::Backoffice::QuantsAuditLog::log(
            $staff,                                                                                                  "updatenewclientlimit",
            sprintf 'client_loginid:%s potential_loss:%s realized_loss:%s client_type:%s market_type:%s expiry: %s', $client,
            $r->params->{'potential_loss'},                                                                          $r->params->{'realized_loss'},
            $r->params->{client_type},                                                                               $r->params->{market_type},
            $r->params->{expiry});

        BOM::Database::Helper::UserSpecificLimit->new({
                db             => $db,
                client_loginid => $client,
                potential_loss => $r->params->{'potential_loss'},
                realized_loss  => $r->params->{'realized_loss'},
                client_type    => $r->params->{client_type},
                market_type    => $r->params->{market_type},
                expiry         => $r->params->{expiry},
            }
            )->record_user_specific_limit
            unless defined $update_error;
    }
}

my $delete_error;
if ($r->params->{'delete_limit'}) {
    if ($r->params->{market_type} !~ /^(?:financial|non_financial)$/ or $r->params->{client_type} !~ /^(?:old|new)$/) {
        $delete_error = 'Market Type and Client Type are required parameters with restricted values';
    }
    $delete_error = "permission denied: no write access" if $disabled_write;

    $args_content = join(q{, }, map { "$_:" . $r->params->{$_} } keys %{$r->params});
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
if ($r->params->{'delete_multiple'} and not $disabled_write) {
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
        disabled           => $disabled_write,
    }) || die BOM::Backoffice::Request::template()->error;

code_exit_BO();
