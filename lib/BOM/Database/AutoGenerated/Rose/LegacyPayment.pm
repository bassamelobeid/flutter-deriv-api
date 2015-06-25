package BOM::Database::AutoGenerated::Rose::LegacyPayment;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table   => 'legacy_payment',
    schema   => 'payment',

    columns => [
        payment_id  => { type => 'bigint', not_null => 1 },
        legacy_type => { type => 'varchar', length => 255 },
    ],

    primary_key_columns => [ 'payment_id' ],

    foreign_keys => [
        payment => {
            class       => 'BOM::Database::AutoGenerated::Rose::Payment',
            key_columns => { payment_id => 'id' },
            rel_type    => 'one to one',
        },
    ],
);

1;

