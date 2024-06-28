#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use BOM::DataView::TableView;
use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use JSON::MaybeUTF8               qw(encode_json_utf8 decode_json_utf8);
use BOM::CFDS::DataSource::PlatformConfig;
use BOM::CFDS::DataSource::PlatformConfigAlert;

BOM::Backoffice::Sysinit::init();
PrintContentType();

my $r = request();

my $cfd_config_table_update_data = $r->param('cfd_config_table_update_data') // '{}';
$cfd_config_table_update_data = decode_json_utf8($cfd_config_table_update_data);

my $action_identifier   = $cfd_config_table_update_data->{action_identifier}   // '';
my $modified_table_data = $cfd_config_table_update_data->{modified_table_data} // {};
my $additional_data     = $cfd_config_table_update_data->{additional_data}     // {};
my $config_type         = $additional_data->{config_type};

BrokerPresentation("CFDS PLATFORM CONFIG");

my $update_list_table_data = {};

if ($action_identifier eq 'spread_update') {
    my $internal_config_data =
        BOM::CFDS::DataSource::PlatformConfig->new()->get_platform_config({platform => 'mt5', config_type => $config_type, table_format => 1});

    my $merged_data = BOM::DataView::TableView::merge_modified_table_data({
        table_formated_data => $internal_config_data,
        modified_table_data => $modified_table_data
    });

    $internal_config_data->{data_items} = $merged_data->{modified_table_data_merged};
    $update_list_table_data = $internal_config_data;
}

if ($action_identifier eq 'spread_consistency_sync_update') {
    my $consistency_alert_data =
        BOM::CFDS::DataSource::PlatformConfigAlert->new()
        ->get_platform_config_alert({platform => 'mt5', config_alert_type => $config_type, table_format => 1});

    my $merged_data = BOM::DataView::TableView::merge_modified_table_data({
        table_formated_data => $consistency_alert_data,
        modified_table_data => $modified_table_data
    });

    push @{$consistency_alert_data->{header}}, 'sync_control';
    $consistency_alert_data->{data_items} = $merged_data->{modified_table_data_merged};
    $update_list_table_data = $consistency_alert_data;
}

my $internal_data_updatelist_table_id = 'mt5_config_update_changelist_table';

my $internal_data_updatelist_searchbox = BOM::DataView::TableView::generate_table_global_search_input_box({
    table_id       => $internal_data_updatelist_table_id,
    header         => $update_list_table_data->{header},
    header_display => $update_list_table_data->{header_display},
});
my $internal_data_updatelist_table = BOM::DataView::TableView::generate_sticky_first_col_header_table({
    table_id => $internal_data_updatelist_table_id,
    data     => $update_list_table_data
});

BOM::Backoffice::Request::template()->process(
    'backoffice/cfds/cfds_platform_config/configs/config_action_confirmation.html.tt',
    {
        html => {
            internal_data => {
                table_id        => $internal_data_updatelist_table_id,
                table_searchbox => $internal_data_updatelist_searchbox,
                table           => $internal_data_updatelist_table,
            }
        },
        table_row_identifier_key   => $update_list_table_data->{unique_column},
        modified_table_data        => encode_json_utf8($modified_table_data),
        modified_table_merged_data => encode_json_utf8($update_list_table_data->{data_items}),
        action_identifier          => $action_identifier,
        config_type                => $config_type,
        return_url                 => request()->url_for('backoffice/cfds/cfds_platform_config/cfds_platform_config.cgi'),
        confirm_url                => request()->url_for('backoffice/cfds/cfds_platform_config/configs/config_action_execution.cgi'),
    });

code_exit_BO();
