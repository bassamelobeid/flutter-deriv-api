package BOM::Database::AutoGenerated::Rose::RunBet;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table  => 'run_bet',
    schema => 'bet',

    columns => [
        financial_market_bet_id => {
            type     => 'bigint',
            not_null => 1
        },
        number_of_ticks => {type => 'integer'},
        last_digit      => {type => 'integer'},
        prediction      => {
            type   => 'varchar',
            length => 20
        },
    ],

    primary_key_columns => ['financial_market_bet_id'],
);

1;

