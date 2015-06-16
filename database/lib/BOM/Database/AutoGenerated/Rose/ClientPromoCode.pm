package BOM::Database::AutoGenerated::Rose::ClientPromoCode;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table   => 'client_promo_code',
    schema   => 'betonmarkets',

    columns => [
        id                      => { type => 'bigint', not_null => 1, sequence => 'sequences.global_serial' },
        client_loginid          => { type => 'varchar', length => 12, not_null => 1 },
        promotion_code          => { type => 'varchar', length => 20, not_null => 1 },
        apply_date              => { type => 'timestamp' },
        status                  => { type => 'varchar', length => 100, not_null => 1 },
        mobile                  => { type => 'varchar', length => 20, not_null => 1 },
        checked_in_myaffiliates => { type => 'boolean', default => 'false', not_null => 1 },
    ],

    primary_key_columns => [ 'id' ],

    unique_key => [ 'client_loginid' ],

    foreign_keys => [
        client => {
            class       => 'BOM::Database::AutoGenerated::Rose::Client',
            key_columns => { client_loginid => 'loginid' },
            rel_type    => 'one to one',
        },

        promotion => {
            class       => 'BOM::Database::AutoGenerated::Rose::PromoCode',
            key_columns => { promotion_code => 'code' },
        },
    ],
);

1;

