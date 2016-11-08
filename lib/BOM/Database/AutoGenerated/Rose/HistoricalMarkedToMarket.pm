package BOM::Database::AutoGenerated::Rose::HistoricalMarkedToMarket;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table  => 'historical_marked_to_market',
    schema => 'accounting',

    columns => [
        id => {
            type     => 'bigint',
            not_null => 1,
            sequence => 'sequences.global_serial'
        },
        calculation_time => {type => 'timestamp'},
        market_value     => {
            type      => 'numeric',
            precision => 4,
            scale     => 10
        },
        delta => {type => 'numeric'},
        theta => {type => 'numeric'},
        vega  => {type => 'numeric'},
        gamma => {type => 'numeric'},
    ],

    primary_key_columns => ['id'],
);

1;

