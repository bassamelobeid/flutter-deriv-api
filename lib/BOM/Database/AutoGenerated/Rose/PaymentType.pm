package BOM::Database::AutoGenerated::Rose::PaymentType;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table  => 'payment_type',
    schema => 'payment',

    columns => [
        code => {
            type     => 'varchar',
            length   => 50,
            not_null => 1
        },
        description => {
            type     => 'varchar',
            length   => 500,
            not_null => 1
        },
    ],

    primary_key_columns => ['code'],

    relationships => [
        payment => {
            class      => 'BOM::Database::AutoGenerated::Rose::Payment',
            column_map => {code => 'payment_type_code'},
            type       => 'one to many',
        },
    ],
);

1;

