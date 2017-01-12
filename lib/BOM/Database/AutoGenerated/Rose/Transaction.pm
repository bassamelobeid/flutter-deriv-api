package BOM::Database::AutoGenerated::Rose::Transaction;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table   => 'transaction',
    schema   => 'transaction',

    columns => [
        id                      => { type => 'bigint', not_null => 1, sequence => 'sequences.transaction_serial' },
        account_id              => { type => 'bigint', not_null => 1 },
        transaction_time        => { type => 'timestamp', default => 'now()' },
        amount                  => { type => 'numeric', not_null => 1 },
        staff_loginid           => { type => 'varchar', length => 24 },
        remark                  => { type => 'varchar', length => 800 },
        referrer_type           => { type => 'varchar', length => 20, not_null => 1 },
        financial_market_bet_id => { type => 'bigint' },
        payment_id              => { type => 'bigint' },
        action_type             => { type => 'varchar', length => 20, not_null => 1 },
        quantity                => { type => 'integer', default => 1 },
        balance_after           => { type => 'numeric' },
        source                  => { type => 'bigint' },
        app_markup              => { type => 'numeric' },
    ],

    primary_key_columns => [ 'id' ],

    allow_inline_column_values => 1,

    foreign_keys => [
        account => {
            class       => 'BOM::Database::AutoGenerated::Rose::Account',
            key_columns => { account_id => 'id' },
        },
    ],
);

1;

