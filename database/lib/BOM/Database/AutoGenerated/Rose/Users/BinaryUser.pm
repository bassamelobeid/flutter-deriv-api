package BOM::Database::AutoGenerated::Rose::Users::BinaryUser;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table   => 'binary_user',
    schema   => 'users',

    columns => [
        id             => { type => 'bigserial', not_null => 1 },
        email          => { type => 'varchar', length => 100, not_null => 1 },
        password       => { type => 'varchar', length => 100, not_null => 1 },
        email_verified => { type => 'boolean', default => 'false', not_null => 1 },
    ],

    primary_key_columns => [ 'id' ],

    unique_key => [ 'email' ],

    relationships => [
        failed_login => {
            class                => 'BOM::Database::AutoGenerated::Rose::Users::FailedLogin',
            column_map           => { id => 'id' },
            type                 => 'one to one',
            with_column_triggers => '0',
        },

        login_history => {
            class      => 'BOM::Database::AutoGenerated::Rose::Users::LoginHistory',
            column_map => { id => 'binary_user_id' },
            type       => 'one to many',
        },

        loginid => {
            class      => 'BOM::Database::AutoGenerated::Rose::Users::Loginid',
            column_map => { id => 'binary_user_id' },
            type       => 'one to many',
        },
    ],
);

1;

