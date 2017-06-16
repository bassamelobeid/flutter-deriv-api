package BOM::Database::AutoGenerated::Rose::CoinauctionBet;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table   => 'coinauction_bet',
    schema   => 'bet',

    columns => [
        financial_market_bet_id => { type => 'bigint', not_null => 1 },
        coin_address            => { type => 'text' },
        token_type              => { type => 'text' },
        number_of_tokens        => { type => 'numeric' },
        auction_date_start      => { type => 'timestamp' },
    ],

    primary_key_columns => [ 'financial_market_bet_id' ],
);

1;

