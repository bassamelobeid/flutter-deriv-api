package BOM::Database::AutoGenerated::Rose::EndOfDayBalance;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table  => 'end_of_day_balances',
    schema => 'accounting',

    columns => [
        id => {
            type     => 'bigint',
            not_null => 1,
            sequence => 'sequences.global_serial'
        },
        account_id => {
            type     => 'bigint',
            not_null => 1
        },
        effective_date => {
            type     => 'timestamp',
            not_null => 1
        },
        balance => {
            type     => 'numeric',
            not_null => 1
        },
    ],

    primary_key_columns => ['id'],

    unique_key => ['account_id', 'effective_date'],

    relationships => [
        end_of_day_open_positions => {
            class      => 'BOM::Database::AutoGenerated::Rose::EndOfDayOpenPosition',
            column_map => {id => 'end_of_day_balance_id'},
            type       => 'one to many',
        },
    ],
);

1;

