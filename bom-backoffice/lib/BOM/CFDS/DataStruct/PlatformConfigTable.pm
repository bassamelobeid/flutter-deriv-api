use Object::Pad;

class BOM::CFDS::DataStruct::PlatformConfigTable;

use strict;
use warnings;
no autovivification;

=head1 NAME

C<BOM::CFDS::DataStruct::PlatformConfigTable>

=head1 DESCRIPTION

A class helper functions to retrieve or set cfds platform configuration related data structured with table data;

=cut

use Object::Pad;

=head2 new

Builder for the class

=cut

BUILD { ; }

=head2 get_spread_table_datastruct

Generate hash in the format that can be used for package BOM::DataView::TableView.

=over 4

=item * C<data_items>  - Array of hash ref of related data.

=back

Hash in the format that can be used for package BOM::DataView::TableView.

=cut

method get_spread_table_datastruct {
    my $args       = shift;
    my $data_items = $args->{data_items};

    return $self->create_table_field({
            header         => ['symbol_name', 'spread_value', 'cfd_platform', 'asset_class', 'updated_at'],
            header_display => {
                symbol_name  => 'Symbol Name',
                spread_value => 'Spread Value',
                cfd_platform => 'CFD Platform',
                asset_class  => 'Asset Class',
                updated_at   => 'Updated At',
            },
            editable_columns => {spread_value => 'number'},
            unique_column    => 'id',
            data_items       => $data_items
        });
}

=head2 get_spread_monitor_alert_table_datastruct

Generate hash in the format that can be used for package BOM::DataView::TableView.

=over 4

=item * C<data_items>  - Array of hash ref of related data.

=back

Hash in the format that can be used for package BOM::DataView::TableView.

=cut

method get_spread_monitor_alert_table_datastruct {
    my $args       = shift;
    my $data_items = $args->{data_items};

    return $self->create_table_field({
            header         => ['symbol_name', 'platform', 'server_type', 'spread_value', 'control_spread_value'],
            header_display => {
                symbol_name          => 'Symbol Name',
                platform             => 'Platform',
                server_type          => 'Server Type',
                spread_value         => 'Spread Value',
                control_spread_value => 'Control Spread Value',
            },
            editable_columns => {},
            unique_column    => 'id',
            data_items       => $data_items
        });
}

=head2 create_table_field

Generate hash in the format that can be used for package BOM::DataView::TableView.

=over 4

=item * C<header>  - Used to determine the header of the table. The order of the header will be the order of the array.
=item * C<header_display>  - Optional alternative text to replace the header key. Use hash with header as key and string as display value.
=item * C<editable_columns>  - Optional. Specify witch column(header key) can be editied. Use hash with header as key and string as value for supported data type for html input.
=item * C<unique_column>  - The column key to be used as unique identifier for each row. Only needed if there is a need to target specific row for modification / selection.
=item * C<data_items>  - Array of hash ref of related data.

=back

Hash in the format that can be used for package BOM::DataView::TableView.

=cut

method create_table_field {
    my $args = shift;

    return {
        header           => $args->{header}           || [],
        header_display   => $args->{header_display}   || {},
        editable_columns => $args->{editable_columns} || {},
        unique_column    => $args->{unique_column}    || '',
        data_items       => $args->{data_items}       || []};
}

return 1;
