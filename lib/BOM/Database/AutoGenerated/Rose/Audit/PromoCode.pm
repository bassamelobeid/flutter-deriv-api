package BOM::Database::AutoGenerated::Rose::Audit::PromoCode;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table  => 'promo_code',
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
        code        => {
            type     => 'varchar',
            length   => 20,
            not_null => 1
        },
        start_date  => {type => 'timestamp'},
        expiry_date => {type => 'timestamp'},
        status      => {
            type     => 'boolean',
            default  => 'true',
            not_null => 1
        },
        promo_code_type => {
            type     => 'varchar',
            length   => 100,
            not_null => 1
        },
        promo_code_config => {
            type     => 'text',
            not_null => 1
        },
        description => {
            type     => 'varchar',
            length   => 255,
            not_null => 1
        },
    ],

    primary_key_columns => ['promo_code_type'],
);

1;

