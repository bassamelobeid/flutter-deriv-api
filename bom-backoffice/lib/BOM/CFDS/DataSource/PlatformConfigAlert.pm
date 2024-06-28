use Object::Pad;

class BOM::CFDS::DataSource::PlatformConfigAlert;

use strict;
use warnings;
no autovivification;

=head1 NAME

C<BOM::CFDS::DataSource::PlatformConfigAlert>

=head1 DESCRIPTION

A class helper functions to retrieve redis stored platform config alert data

=cut

use Object::Pad;
use BOM::Config;
use BOM::CFDS::DataStruct::PlatformConfigTable;
use RedisDB;
use JSON::MaybeUTF8 qw(decode_json_utf8);
use BOM::Config;

=head2 redis

RedisDB instance

=cut

field $redis : reader;

=head2 platform_redis_key

Key name to get from redis connection

=cut

field $platform_redis_key : reader = {
    mt5 => {
        spread => 'MT5::Alert::SpreadMismatch',
    },
};

=head2 mt5_config

MT5 config data

=cut

field $mt5_config : reader;

=head2 new

Builder for the class

=cut

BUILD {
    my $redis_config = BOM::Config::redis_mt5_user_config();
    $redis = RedisDB->new(
        host     => $redis_config->{write}{host},
        port     => $redis_config->{write}{port},
        password => $redis_config->{write}{password},
    );

    $mt5_config = BOM::Config::mt5_webapi_config();
}

=head2 get_platform_config_alert

Get incosistency alert data saved in redis

=over 4

=item * C<platform>  - Platform name. Currently only support mt5

=item * C<config_alert_type>  - Config Alert type. Currently only support spread

=item * C<table_format>  - Return data in table format used by package BOM::DataView::TableView

=back

Array of data or in table formated data if table_format is provided

=cut

method get_platform_config_alert {
    my $args              = shift;
    my $config_alert_type = $args->{config_alert_type};

    return $self->get_spread_config_alert($args) if $config_alert_type eq 'spread';
}

=head2 get_spread_config_alert

Get spread incosistency alert data saved in redis

Expected example redis data format in array of following items:

    Vol 10 => {
        id                   => 1,
        platform             => mt5,
        spread_value         => 5,
        control_spread_value => 2,
    }

=over 4

=item * C<platform>  - Platform name. Currently only support mt5

=item * C<config_alert_type>  - Config Alert type. Currently only support spread

=item * C<table_format>  - Return data in table format used by package BOM::DataView::TableView

=back

Array of data or in table formated data if table_format is provided

=cut

method get_spread_config_alert {
    my $args               = shift;
    my $is_table_formatted = $args->{table_format};

    my $redis_keys = $self->generate_redis_key_list($args);
    my $alert_data = [];
    foreach my $redis_key (@{$redis_keys}) {
        my %mismatch_data = @{$redis->execute('hgetall', $redis_key)};
        foreach my $key (keys %mismatch_data) {
            my $decoded_hash = decode_json_utf8($mismatch_data{$key});
            push @{$alert_data},
                {
                id                   => $decoded_hash->{id},
                symbol_name          => $key,
                platform             => $decoded_hash->{platform},
                server_type          => $decoded_hash->{server_type},
                spread_value         => $decoded_hash->{got},
                control_spread_value => $decoded_hash->{expected},
                };
        }
    }

    return BOM::CFDS::DataStruct::PlatformConfigTable->new()->get_spread_monitor_alert_table_datastruct({data_items => $alert_data})
        if $is_table_formatted;

    return $alert_data;
}

=head2 generate_redis_key_list

Get a list of related redis key to get data from

=over 4

=item * C<platform>  - Platform name. Currently only support mt5

=item * C<config_alert_type>  - Config Alert type. Currently only support spread

=back

Array of redis keys.

=cut

method generate_redis_key_list {
    my $args              = shift;
    my $platform          = $args->{platform};
    my $config_alert_type = $args->{config_alert_type};

    my $base_key = $platform_redis_key->{$platform}{$config_alert_type};
    return $self->mt5_redis_key_list($base_key) if $platform eq 'mt5';
}

=head2 mt5_redis_key_list

Generate a list of related redis key for mt5 platform main trade server.

=over 4

=item * C<base_key>  - The common prefix key for the redis key used by all the related keys

=back

Array of redis keys.

[
  "MT5::Alert::SpreadMismatch::p03_ts01::real",
  "MT5::Alert::SpreadMismatch::p02_ts01::real",
  "MT5::Alert::SpreadMismatch::p01_ts01::real",
  "MT5::Alert::SpreadMismatch::p01_ts01::demo",
]

=cut

method mt5_redis_key_list {
    my $base_key = shift;
    my @redis_keys;

    foreach my $server_type (qw/real demo/) {
        foreach my $server_id (keys %{$mt5_config->{$server_type}}) {
            if ($server_id =~ /_ts01$/) {
                my $redis_key = join('::', $base_key, $server_id, $server_type);
                push @redis_keys, $redis_key;
            }
        }
    }

    return \@redis_keys;
}

return 1;
