package BOM::Database::AutoGenerated::Rose::Audit::Transaction;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table  => 'transaction',
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
        client_addr => {type => 'scalar'},
        client_port => {type => 'integer'},
        id          => {
            type     => 'bigint',
            not_null => 1
        },
        account_id => {
            type     => 'bigint',
            not_null => 1
        },
        transaction_time => {
            type    => 'timestamp',
            default => 'now()'
        },
        amount => {
            type     => 'numeric',
            not_null => 1
        },
        staff_loginid => {
            type   => 'varchar',
            length => 24
        },
        remark => {
            type   => 'varchar',
            length => 800
        },
        referrer_type => {
            type     => 'varchar',
            length   => 20,
            not_null => 1
        },
        financial_market_bet_id => {type => 'bigint'},
        payment_id              => {type => 'bigint'},
        action_type             => {
            type     => 'varchar',
            length   => 20,
            not_null => 1
        },
        quantity => {
            type    => 'integer',
            default => 1
        },
    ],

    primary_key_columns => ['id'],

    allow_inline_column_values => 1,
);

1;

