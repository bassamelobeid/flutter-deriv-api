package BOM::Database::AutoGenerated::Rose::Users::LoginHistory;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table   => 'login_history',
    schema   => 'users',

    columns => [
        id             => { type => 'bigserial', not_null => 1 },
        binary_user_id => { type => 'bigint', not_null => 1 },
        action         => { type => 'varchar', length => 15, not_null => 1 },
        history_date   => { type => 'timestamp', default => 'now()' },
        environment    => { type => 'varchar', length => 1024, not_null => 1 },
        successful     => { type => 'boolean', not_null => 1 },
    ],

    primary_key_columns => [ 'id' ],

    allow_inline_column_values => 1,

    foreign_keys => [
        binary_user => {
            class       => 'BOM::Database::AutoGenerated::Rose::Users::BinaryUser',
            key_columns => { binary_user_id => 'id' },
        },
    ],
);

1;

