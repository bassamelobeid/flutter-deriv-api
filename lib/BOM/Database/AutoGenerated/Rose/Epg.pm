package BOM::Database::AutoGenerated::Rose::Epg;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table  => 'epg',
    schema => 'payment',

    columns => [
        payment_id => {
            type     => 'bigint',
            not_null => 1
        },
        transaction_type => {
            type     => 'varchar',
            length   => 15,
            not_null => 1
        },
        trace_id => {
            type     => 'bigint',
            not_null => 1
        },
        created_by => {
            type   => 'varchar',
            length => 50
        },
        payment_processor => {
            type     => 'varchar',
            length   => 50,
            not_null => 1
        },
        ip_address => {
            type   => 'varchar',
            length => 15
        },
        transaction_id => {
            type   => 'varchar',
            length => 100
        },
    ],

    primary_key_columns => ['payment_id'],

    foreign_keys => [
        payment => {
            class       => 'BOM::Database::AutoGenerated::Rose::Payment',
            key_columns => {payment_id => 'id'},
            rel_type    => 'one to one',
        },
    ],
);

1;

