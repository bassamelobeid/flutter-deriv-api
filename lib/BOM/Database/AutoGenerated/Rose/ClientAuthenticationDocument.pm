package BOM::Database::AutoGenerated::Rose::ClientAuthenticationDocument;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table   => 'client_authentication_document',
    schema   => 'betonmarkets',

    columns => [
        id                         => { type => 'bigint', not_null => 1, sequence => 'sequences.global_serial' },
        document_type              => { type => 'varchar', length => 100, not_null => 1 },
        document_format            => { type => 'varchar', length => 100, not_null => 1 },
        document_path              => { type => 'varchar', length => 255, not_null => 1 },
        client_loginid             => { type => 'varchar', length => 12, not_null => 1 },
        authentication_method_code => { type => 'varchar', length => 50, not_null => 1 },
        expiration_date            => { type => 'date' },
        comments                   => { type => 'varchar', default => '', length => 255, not_null => 1 },
    ],

    primary_key_columns => [ 'id' ],

    foreign_keys => [
        client => {
            class       => 'BOM::Database::AutoGenerated::Rose::Client',
            key_columns => { client_loginid => 'loginid' },
        },
    ],
);

1;

