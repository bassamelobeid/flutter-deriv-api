#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use BOM::DataView::TableView;
use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use JSON::MaybeUTF8               qw(decode_json_utf8);
use BOM::CFDS::DataSource::PlatformConfig;
use BOM::CFDS::DataSource::PlatformConfigAlert;

BOM::Backoffice::Sysinit::init();
PrintContentType();

use constant CONFIG_TYPE_TO_ACTION_IDENTIFIER => {
    'spread' => {
        'internal_config'   => 'spread_update',
        'consistency_alert' => 'spread_consistency_sync_update',
    },
};

my $r                    = request();
my $config_type          = $r->param('config_type')          // 'spread';
my $action_identifier    = $r->param('action_identifier')    // '';
my $table_update_data    = $r->param('table_update_data')    // '';
my $resume_modified_data = $r->param('resume_modified_data') // '{}';
$resume_modified_data = $resume_modified_data ? decode_json_utf8($resume_modified_data) : {};

BrokerPresentation("CFDS PLATFORM CONFIG");

# Internal Config
my $internal_config_data_table_id          = 'internal_config_table';
my $internal_config_data_action_identifier = CONFIG_TYPE_TO_ACTION_IDENTIFIER->{$config_type}->{'internal_config'};

my $internal_config_data =
    BOM::CFDS::DataSource::PlatformConfig->new()->get_platform_config({platform => 'mt5', config_type => $config_type, table_format => 1});

if (keys %{$resume_modified_data} and $action_identifier eq $internal_config_data_action_identifier) {
    my $merged_data = BOM::DataView::TableView::merge_modified_table_data({
        table_formated_data => $internal_config_data,
        modified_table_data => $resume_modified_data
    });
    $internal_config_data = $merged_data->{table_formated_data_merged};
}

my $internal_data_table_searchbox = BOM::DataView::TableView::generate_table_global_search_input_box({
    table_id       => $internal_config_data_table_id,
    header         => $internal_config_data->{header},
    header_display => $internal_config_data->{header_display},
});

my $internal_data_table =
    BOM::DataView::TableView::generate_sticky_first_col_header_table({table_id => $internal_config_data_table_id, data => $internal_config_data});

my $internal_data_table_editbutton = BOM::DataView::TableView::generate_table_edit_save_button({
    table_id             => $internal_config_data_table_id,
    action_identifier    => $internal_config_data_action_identifier,
    form_input_ref_name  => 'cfd_config_table_update_data',
    redirect_url         => request()->url_for('backoffice/cfds/cfds_platform_config/configs/config_action_confirmation.cgi'),
    resume_modified_data => $action_identifier eq $internal_config_data_action_identifier ? $resume_modified_data : undef,
    additional_data      => {config_type => $config_type},
});

# Alert
my $consistency_alert_table_id          = 'consistency_alert_table';
my $consistency_alert_action_identifier = CONFIG_TYPE_TO_ACTION_IDENTIFIER->{$config_type}->{'consistency_alert'};

my $consistency_alert_data =
    BOM::CFDS::DataSource::PlatformConfigAlert->new()
    ->get_platform_config_alert({platform => 'mt5', config_alert_type => $config_type, table_format => 1});

if (keys %{$resume_modified_data} and $action_identifier eq $consistency_alert_action_identifier) {
    my $merged_data = BOM::DataView::TableView::merge_modified_table_data({
        table_formated_data => $consistency_alert_data,
        modified_table_data => $resume_modified_data
    });
    $consistency_alert_data = $merged_data->{table_formated_data_merged};
}

my $consistency_alert_searchbox = BOM::DataView::TableView::generate_table_global_search_input_box({
    table_id       => $consistency_alert_table_id,
    header         => $consistency_alert_data->{header},
    header_display => $consistency_alert_data->{header_display},
});
my $consistency_alert_table = BOM::DataView::TableView::generate_sticky_first_col_last_col_with_checkbox_header_table({
    table_id => $consistency_alert_table_id,
    data     => $consistency_alert_data
});
my $consistency_alert_table_confirmbutton = BOM::DataView::TableView::generate_table_confirm_checkbox_button({
    table_id             => $consistency_alert_table_id,
    action_identifier    => $consistency_alert_action_identifier,
    form_input_ref_name  => 'cfd_config_table_update_data',
    redirect_url         => request()->url_for('backoffice/cfds/cfds_platform_config/configs/config_action_confirmation.cgi'),
    resume_modified_data => $action_identifier eq $consistency_alert_action_identifier ? $resume_modified_data : undef,
    additional_data      => {config_type => $config_type},
});

BOM::Backoffice::Request::template()->process(
    'backoffice/cfds/cfds_platform_config/cfds_platform_config.html.tt',
    {
        html => {
            internal_data => {
                table_searchbox  => $internal_data_table_searchbox,
                table            => $internal_data_table,
                table_editbutton => $internal_data_table_editbutton,
            },
            consistency_alert_data => {
                table_searchbox     => $consistency_alert_searchbox,
                table               => $consistency_alert_table,
                table_confirmbutton => $consistency_alert_table_confirmbutton,
            }
        },
        config_type => $config_type,
    });

code_exit_BO();
