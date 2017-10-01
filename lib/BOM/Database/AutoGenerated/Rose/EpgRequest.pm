package BOM::Database::AutoGenerated::Rose::EpgRequest;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table  => 'epg_request',
    schema => 'payment',

    columns => [
        id => {
            type     => 'varchar',
            length   => 36,
            not_null => 1
        },
        payment_time => {
            type    => 'timestamp',
            default => 'now()'
        },
        amount => {
            type      => 'numeric',
            not_null  => 1,
            precision => 4,
            scale     => 14
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
        payment_currency => {
            type     => 'varchar',
            length   => 3,
            not_null => 1
        },
        payment_country => {
            type     => 'varchar',
            length   => 12,
            not_null => 1
        },
        remark         => {type => 'text'},
        transaction_id => {
            type   => 'varchar',
            length => 100
        },
        ip_address => {
            type   => 'varchar',
            length => 64
        },
    ],

    primary_key_columns => ['id'],

    allow_inline_column_values => 1,
);

1;

