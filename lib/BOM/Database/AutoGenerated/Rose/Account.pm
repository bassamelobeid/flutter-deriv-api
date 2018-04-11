package BOM::Database::AutoGenerated::Rose::Account;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table   => 'account',
    schema   => 'transaction',

    columns => [
        id             => { type => 'bigint', not_null => 1, sequence => 'sequences.account_serial' },
        client_loginid => { type => 'varchar', length => 12, not_null => 1 },
        currency_code  => { type => 'varchar', not_null => 1 },
        balance        => { type => 'numeric', default => '0', not_null => 1 },
        is_default     => { type => 'boolean', default => 'true', not_null => 1 },
        last_modified  => { type => 'timestamp' },
        binary_user_id => { type => 'bigint' },
    ],

    primary_key_columns => [ 'id' ],

    unique_key => [ 'client_loginid', 'currency_code' ],

    relationships => [
        transaction => {
            class      => 'BOM::Database::AutoGenerated::Rose::Transaction',
            column_map => { id => 'account_id' },
            type       => 'one to many',
        },
    ],
);

1;

