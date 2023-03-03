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
        document_id                => { type => 'varchar', default => '', length => 30, not_null => 1 },
        status                     => { type => 'enum', check_in => [ 'uploading', 'uploaded', 'verified', 'rejected' ], db_type => 'status_type' },
        file_name                  => { type => 'varchar', length => 100 },
        checksum                   => { type => 'varchar', length => 40, not_null => 1 },
        upload_date                => { type => 'timestamp' },
        issue_date                 => { type => 'date' },
        lifetime_valid             => { type => 'boolean', default => 0},
        origin                     => { type => 'enum', check_in => [ 'bo', 'client', 'onfido', 'legacy', 'idv' ], db_type => 'betonmarkets.client_document_origin', 'default' => 'legacy' },
    ],

    primary_key_columns => [ 'id' ],

    unique_key => [ 'document_type', 'client_loginid', 'checksum' ],

    foreign_keys => [
        client => {
            class       => 'BOM::Database::AutoGenerated::Rose::Client',
            key_columns => { client_loginid => 'loginid' },
        },
    ],
);

1;

