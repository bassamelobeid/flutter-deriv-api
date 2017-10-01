package BOM::Database::AutoGenerated::Rose::WesternUnion;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table  => 'western_union',
    schema => 'payment',

    columns => [
        payment_id => {
            type     => 'bigint',
            not_null => 1
        },
        mtcn_number => {
            type     => 'varchar',
            length   => 15,
            not_null => 1
        },
        payment_country => {
            type     => 'varchar',
            length   => 64,
            not_null => 1
        },
        secret_answer => {
            type   => 'varchar',
            length => 128
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

