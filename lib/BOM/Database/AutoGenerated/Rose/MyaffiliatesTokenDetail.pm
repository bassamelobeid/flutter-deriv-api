package BOM::Database::AutoGenerated::Rose::MyaffiliatesTokenDetail;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table   => 'myaffiliates_token_details',
    schema   => 'data_collection',

    columns => [
        token    => { type => 'text', not_null => 1 },
        user_id  => { type => 'bigint' },
        username => { type => 'text' },
        status   => { type => 'text' },
        email    => { type => 'text' },
        tags     => { type => 'text' },
    ],

    primary_key_columns => [ 'token' ],
);

1;

