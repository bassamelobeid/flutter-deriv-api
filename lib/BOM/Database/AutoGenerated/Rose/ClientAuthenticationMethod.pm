package BOM::Database::AutoGenerated::Rose::ClientAuthenticationMethod;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table   => 'client_authentication_method',
    schema   => 'betonmarkets',

    columns => [
        id                         => { type => 'bigint', not_null => 1, sequence => 'sequences.global_serial' },
        client_loginid             => { type => 'varchar', length => 12, not_null => 1 },
        authentication_method_code => { type => 'varchar', length => 50, not_null => 1 },
        last_modified_date         => { type => 'timestamp' },
        status                     => { type => 'varchar', length => 100, not_null => 1 },
        description                => { type => 'text', default => '', not_null => 1 },
    ],

    primary_key_columns => [ 'id' ],

    unique_key => [ 'client_loginid', 'authentication_method_code' ],

    foreign_keys => [
        client => {
            class       => 'BOM::Database::AutoGenerated::Rose::Client',
            key_columns => { client_loginid => 'loginid' },
        },
    ],
);

1;

