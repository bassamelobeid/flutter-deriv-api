package BOM::Database::AutoGenerated::Rose::BetDictionary;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table  => 'bet_dictionary',
    schema => 'bet',

    columns => [
        id => {
            type     => 'bigint',
            not_null => 1,
            sequence => 'sequences.global_serial'
        },
        bet_type => {
            type     => 'varchar',
            length   => 30,
            not_null => 1
        },
        path_dependent => {type => 'boolean'},
        table_name     => {
            type     => 'varchar',
            length   => 30,
            not_null => 1
        },
    ],

    primary_key_columns => ['id'],

    unique_key => ['bet_type'],

    relationships => [
        financial_market_bet => {
            class      => 'BOM::Database::AutoGenerated::Rose::FinancialMarketBet',
            column_map => {bet_type => 'bet_type'},
            type       => 'one to many',
        },

        financial_market_bet_open => {
            class      => 'BOM::Database::AutoGenerated::Rose::FinancialMarketBetOpen',
            column_map => {bet_type => 'bet_type'},
            type       => 'one to many',
        },
    ],
);

1;

