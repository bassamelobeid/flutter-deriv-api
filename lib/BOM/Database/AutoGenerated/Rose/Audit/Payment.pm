package BOM::Database::AutoGenerated::Rose::Audit::Payment;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table  => 'payment',
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
        payment_time => {
            type    => 'timestamp',
            default => 'now()'
        },
        amount => {
            type     => 'numeric',
            not_null => 1
        },
        payment_gateway_code => {
            type     => 'varchar',
            length   => 50,
            not_null => 1
        },
        payment_type_code => {
            type     => 'varchar',
            length   => 50,
            not_null => 1
        },
        status => {
            type     => 'varchar',
            length   => 20,
            not_null => 1
        },
        account_id => {
            type     => 'bigint',
            not_null => 1
        },
        staff_loginid => {
            type     => 'varchar',
            length   => 12,
            not_null => 1
        },
        remark => {
            type     => 'varchar',
            default  => '',
            length   => 800,
            not_null => 1
        },
    ],

    primary_key_columns => ['id'],

    allow_inline_column_values => 1,
);

1;

