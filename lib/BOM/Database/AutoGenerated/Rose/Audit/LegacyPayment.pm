package BOM::Database::AutoGenerated::Rose::Audit::LegacyPayment;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table  => 'legacy_payment',
    schema => 'audit',

    columns => [
        operation => {
            type     => 'varchar',
            length   => 10,
            not_null => 1
        },
        stamp => {
            type     => 'timestamp',
            not_null => 1
        },
        pg_userid => {
            type     => 'text',
            not_null => 1
        },
        client_addr => {type => 'scalar'},
        client_port => {type => 'integer'},
        payment_id  => {
            type     => 'bigint',
            not_null => 1
        },
        legacy_type => {
            type   => 'varchar',
            length => 255
        },
    ],

    primary_key_columns => ['stamp'],
);

1;

