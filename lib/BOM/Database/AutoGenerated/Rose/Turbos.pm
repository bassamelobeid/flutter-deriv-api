package BOM::Database::AutoGenerated::Rose::Turbos;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table  => 'turbos',
    schema => 'bet',

    columns => [
        financial_market_bet_id => {
            type     => 'bigint',
            not_null => 1
        },
        entry_epoch              => {type => 'timestamp'},
        entry_spot               => {type => 'numeric'},
        barrier                  => {type => 'numeric'},
        take_profit_order_amount => {type => 'numeric'},
        take_profit_order_date   => {type => 'timestamp'},
        ask_spread               => {type => 'numeric'},
        bid_spread               => {type => 'numeric'},
    ],

    primary_key_columns => ['financial_market_bet_id'],
);

1;
