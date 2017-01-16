package BOM::Database::AutoGenerated::Rose::ExchangeRate;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table   => 'exchange_rate',
    schema   => 'data_collection',

    columns => [
        id              => { type => 'bigint', not_null => 1, sequence => 'sequences.global_serial' },
        source_currency => { type => 'character', length => 3, not_null => 1 },
        target_currency => { type => 'character', length => 3, not_null => 1 },
        date            => { type => 'timestamp' },
        rate            => { type => 'numeric', precision => 12, scale => 24 },
    ],

    primary_key_columns => [ 'id' ],

    unique_key => [ 'source_currency', 'target_currency', 'date' ],
);

1;

