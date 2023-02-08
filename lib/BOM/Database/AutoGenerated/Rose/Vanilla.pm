package BOM::Database::AutoGenerated::Rose::Vanilla;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table  => 'vanilla',
    schema => 'bet',

    columns => [
        financial_market_bet_id => {
            type     => 'bigint',
            not_null => 1
        },
        entry_epoch => { type => 'timestamp' },
        entry_spot => { type => 'numeric' },
        barrier => { type => 'numeric' },
        commission  => { type => 'numeric' },
    ],

    primary_key_columns => ['financial_market_bet_id'],
);

1;
