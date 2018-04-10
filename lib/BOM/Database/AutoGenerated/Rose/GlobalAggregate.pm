package BOM::Database::AutoGenerated::Rose::GlobalAggregate;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table   => 'global_aggregates',
    schema   => 'bet',

    columns => [
        day            => { type => 'date', not_null => 1 },
        symbol         => { type => 'text', not_null => 1 },
        contract_group => { type => 'text', not_null => 1 },
        expiry_type    => { type => 'enum', check_in => [ 'intraday', 'daily', 'tick' ], db_type => 'bet.expiry_type', not_null => 1 },
        is_atm         => { type => 'boolean', not_null => 1 },
        is_aggregate   => { type => 'boolean', default => 'false', not_null => 1 },
        cnt            => { type => 'bigint', not_null => 1 },
        buy_price      => { type => 'numeric', not_null => 1 },
        sell_price     => { type => 'numeric', not_null => 1 },
    ],

    primary_key_columns => [ 'symbol' ],
);

1;

