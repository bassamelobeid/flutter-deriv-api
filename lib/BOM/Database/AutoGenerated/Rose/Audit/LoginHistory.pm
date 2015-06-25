package BOM::Database::AutoGenerated::Rose::Audit::LoginHistory;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table   => 'login_history',
    schema   => 'audit',

    columns => [
        operation         => { type => 'varchar', length => 10, not_null => 1 },
        stamp             => { type => 'timestamp', not_null => 1 },
        pg_userid         => { type => 'text', not_null => 1 },
        client_addr       => { type => 'scalar' },
        client_port       => { type => 'integer' },
        id                => { type => 'bigint', not_null => 1 },
        client_loginid    => { type => 'varchar', length => 12, not_null => 1 },
        login_environment => { type => 'varchar', length => 1024, not_null => 1 },
        login_date        => { type => 'timestamp', default => 'now()' },
        login_successful  => { type => 'boolean', not_null => 1 },
        login_action      => { type => 'varchar', length => 255, not_null => 1 },
    ],

    primary_key_columns => [ 'id' ],

    allow_inline_column_values => 1,
);

1;

