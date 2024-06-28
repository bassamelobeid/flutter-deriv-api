use Object::Pad;

class BOM::CFDS::DataSource::PlatformConfig;

use strict;
use warnings;
no autovivification;

=head1 NAME

C<BOM::CFDS::DataSource::PlatformConfig>

=head1 DESCRIPTION

A class helper functions to retrieve or set cfds platform configuration related data

=cut

use Object::Pad;
use Syntax::Keyword::Try;
use BOM::CFDS::DataStruct::PlatformConfigTable;
use BOM::Database::ClientDB;

=head2 new

Builder for the class

=cut

BUILD { ; }

=head2 get_platform_config

Get CFD platform config saved locally in DB

=over 4

=item * C<platform>  - Platform name. Currently only support mt5

=item * C<config_type>  - Config type. Currently only support spread

=item * C<table_format>  - Return data in table format used by package BOM::DataView::TableView

=back

Array of data or in table formated data if table_format is provided

=cut

method get_platform_config {
    my $args     = shift;
    my $platform = $args->{platform};

    return $self->get_mt5_platform_config($args) if $platform eq 'mt5';
}

=head2 get_mt5_platform_config

Get MT5 platform config saved locally in DB

=over 4

=item * C<config_type>  - Config type. Currently only support spread

=back

Array of data or in table formated data if table_format is provided

=cut

method get_mt5_platform_config {
    my $args        = shift;
    my $config_type = $args->{config_type};

    return $self->get_internal_spread_config($args) if $config_type eq 'spread';
}

=head2 get_internal_spread_config

Get platform spread config saved locally in DB

=over 4

=item * C<platform>  - Platform name. Currently only support mt5

=item * C<table_format>  - Return data in table format used by package BOM::DataView::TableView

=back

Array of data or in table formated data if table_format is provided

=cut

method get_internal_spread_config {
    my $args               = shift;
    my $platform           = $args->{platform};
    my $is_table_formatted = $args->{table_format};

    my $internal_data = $self->_dbic_collector->run(
        fixup => sub {
            $_->selectall_arrayref('SELECT * FROM cfd.symbol_data WHERE cfd_platform = ?', {Slice => {}}, $platform);
        });

    return BOM::CFDS::DataStruct::PlatformConfigTable->new()->get_spread_table_datastruct({data_items => $internal_data}) if $is_table_formatted;

    return $internal_data;
}

=head2 update_internal_spread_config

Update platform spread config saved locally in DB

=over 4

=item * C<symbol_id>  - Unique ID for the symbol

=item * C<spread_value>  - Spread value for the symbol

=item * C<platform>  - Platform name.

=item * C<asset_class>  - Asset class for the symbol

=back

=cut

method update_internal_spread_config {
    my $args = shift;
    my ($symbol_id, $spread_value, $platform, $asset_class) = @{$args}{qw/symbol_id spread_value platform asset_class/};

    my $update_result;
    try {
        $update_result = $self->_dbic_collector->run(
            fixup => sub {
                $_->selectrow_hashref('SELECT * FROM cfd.update_symbol_data(?,?,?,?)', undef, $symbol_id, $spread_value, $platform, $asset_class);
            });
    } catch ($e) {
        die "$e \n";
    }

    die "DB returned with undefined update result \n" unless defined $update_result;

    my $updated_spread_value = $update_result->{spread_value};
    die "Error updating spread value. New value requested: $spread_value. DB update operation return spread value: $updated_spread_value \n"
        if $updated_spread_value ne $spread_value;
}

=head2 _dbic_collector

Return db connection of collector client db

=over 4

=back

=cut

method _dbic_collector {
    return BOM::Database::ClientDB->new({
            broker_code => 'FOG',
            operation   => 'collector'
        })->db->dbic;
}

return 1;
