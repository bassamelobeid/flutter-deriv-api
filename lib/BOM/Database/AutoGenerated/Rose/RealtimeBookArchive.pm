package BOM::Database::AutoGenerated::Rose::RealtimeBookArchive;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table   => 'realtime_book_archive',
    schema   => 'accounting',

    columns => [
        id                      => { type => 'bigint', not_null => 1 },
        calculation_time        => { type => 'timestamp', default => 'now()' },
        financial_market_bet_id => { type => 'bigint' },
        market_price            => { type => 'numeric' },
        delta                   => { type => 'numeric' },
        theta                   => { type => 'numeric' },
        vega                    => { type => 'numeric' },
        gamma                   => { type => 'numeric' },
    ],

    primary_key_columns => [ 'id' ],

    allow_inline_column_values => 1,
);

1;

