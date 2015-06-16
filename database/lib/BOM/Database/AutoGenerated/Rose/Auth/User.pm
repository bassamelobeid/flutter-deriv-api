package BOM::Database::AutoGenerated::Rose::Auth::User;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table   => 'users',
    schema   => 'auth',

    columns => [
        id    => { type => 'serial', not_null => 1 },
        login => { type => 'varchar', length => 12, not_null => 1 },
    ],

    primary_key_columns => [ 'id' ],

    unique_key => [ 'login' ],

    relationships => [
        grants => {
            class      => 'BOM::Database::AutoGenerated::Rose::Auth::Grant',
            column_map => { id => 'user_id' },
            type       => 'one to many',
        },
    ],
);

1;

