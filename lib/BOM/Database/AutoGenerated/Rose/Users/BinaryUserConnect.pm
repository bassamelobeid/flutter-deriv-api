package BOM::Database::AutoGenerated::Rose::Users::BinaryUserConnect;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table  => 'binary_user_connects',
    schema => 'users',

    columns => [
        id => {
            type     => 'bigserial',
            not_null => 1
        },
        binary_user_id => {
            type     => 'bigint',
            not_null => 1
        },
        provider => {
            type     => 'varchar',
            length   => 24,
            not_null => 1
        },
        provider_identity_uid => {
            type     => 'varchar',
            length   => 64,
            not_null => 1
        },
        provider_data => {
            type     => 'scalar',
            not_null => 1
        },
        date => {
            type    => 'timestamp',
            default => 'now()'
        },
    ],

    primary_key_columns => ['id'],

    unique_keys => [['provider', 'provider_identity_uid'], ['binary_user_id', 'provider'],],

    allow_inline_column_values => 1,

    foreign_keys => [
        binary_user => {
            class       => 'BOM::Database::AutoGenerated::Rose::Users::BinaryUser',
            key_columns => {binary_user_id => 'id'},
        },
    ],
);

1;

