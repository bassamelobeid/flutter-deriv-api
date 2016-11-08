package BOM::Database::AutoGenerated::Rose::Audit::CurrencyConversionTransfer;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table   => 'currency_conversion_transfer',
    schema   => 'audit',

    columns => [
        operation                => { type => 'varchar', length => 10, not_null => 1 },
        stamp                    => { type => 'timestamp', not_null => 1 },
        pg_userid                => { type => 'text', not_null => 1 },
        client_addr              => { type => 'scalar' },
        client_port              => { type => 'integer' },
        payment_id               => { type => 'bigint', not_null => 1 },
        corresponding_payment_id => { type => 'bigint' },
    ],

    primary_key_columns => [ 'stamp' ],
);

1;

