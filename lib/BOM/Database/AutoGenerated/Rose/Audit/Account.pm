package BOM::Database::AutoGenerated::Rose::Audit::Account;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table  => 'account',
    schema => 'audit',

    columns => [
        operation => {
            type     => 'varchar',
            length   => 10,
            not_null => 1
        },
        stamp => {
            type     => 'timestamp',
            not_null => 1
        },
        pg_userid => {
            type     => 'text',
            not_null => 1
        },
        client_addr => {type => 'scalar'},
        client_port => {type => 'integer'},
        id          => {
            type     => 'bigint',
            not_null => 1
        },
        client_loginid => {
            type     => 'varchar',
            length   => 12,
            not_null => 1
        },
        currency_code => {
            type     => 'varchar',
            length   => 3,
            not_null => 1
        },
        balance => {
            type      => 'numeric',
            default   => '0',
            not_null  => 1,
            precision => 4,
            scale     => 14
        },
        is_default => {
            type     => 'boolean',
            default  => 'true',
            not_null => 1
        },
        last_modified => {type => 'timestamp'},
    ],

    primary_key_columns => ['id'],
);

1;

