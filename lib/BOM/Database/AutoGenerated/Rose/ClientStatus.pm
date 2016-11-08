package BOM::Database::AutoGenerated::Rose::ClientStatus;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table   => 'client_status',
    schema   => 'betonmarkets',

    columns => [
        id                 => { type => 'bigint', not_null => 1, sequence => 'sequences.global_serial' },
        client_loginid     => { type => 'varchar', length => 12, not_null => 1 },
        status_code        => { type => 'varchar', length => 32, not_null => 1 },
        staff_name         => { type => 'varchar', length => 100, not_null => 1 },
        reason             => { type => 'varchar', length => 1000, not_null => 1 },
        last_modified_date => { type => 'timestamp', default => 'now()' },
    ],

    primary_key_columns => [ 'id' ],

    unique_key => [ 'client_loginid', 'status_code' ],

    allow_inline_column_values => 1,

    foreign_keys => [
        client => {
            class       => 'BOM::Database::AutoGenerated::Rose::Client',
            key_columns => { client_loginid => 'loginid' },
        },
    ],
);

1;

