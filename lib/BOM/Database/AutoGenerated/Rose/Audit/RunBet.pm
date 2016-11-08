package BOM::Database::AutoGenerated::Rose::Audit::RunBet;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table  => 'run_bet',
    schema => 'audit',

    columns => [
        operation => {
            type     => 'varchar',
            length   => 10,
            not_null => 1
        },
        stamp => {
            type     => 'timestamp',
            not_null => 1
        },
        pg_userid => {
            type     => 'text',
            not_null => 1
        },
        client_addr             => {type => 'scalar'},
        client_port             => {type => 'integer'},
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

    primary_key_columns => ['number_of_ticks'],
);

1;

