package BOM::Database::AutoGenerated::Rose::Cryptocurrency;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table   => 'cryptocurrency',
    schema   => 'payment',

    columns => [
        address          => { type => 'varchar', length => 100, not_null => 1 },
        currency_code    => { type => 'varchar', length => 3, not_null => 1 },
        id               => { type => 'bigserial', not_null => 1 },
        client_loginid   => { type => 'varchar', length => 12 },
        amount           => { type => 'numeric' },
        fee              => { type => 'numeric' },
        transaction_type => { type => 'enum', check_in => [ 'deposit', 'withdrawal' ], db_type => 'payment.payment_txn_type', not_null => 1 },
        status           => { type => 'enum', check_in => [ 'NEW', 'PENDING', 'CONFIRMED', 'LOCKED', 'VERIFIED', 'REJECTED', 'PROCESSING', 'SENT', 'ERROR', 'RESOLVED', 'PERFORMING_BLOCKCHAIN_TXN', 'MIGRATED' ], db_type => 'payment.ctc_status', not_null => 1 },
        payment_id       => { type => 'bigint' },
        ip_address       => { type => 'scalar' },
        remark           => { type => 'text' },
        error_text       => { type => 'text' },
        resolution       => { type => 'text' },
        blockchain_txn   => { type => 'text' },
        txn_fee          => { type => 'numeric' },
        estimated_fee    => { type => 'numeric' },
    ],

    primary_key_columns => [ 'address', 'currency_code' ],

    unique_key => [ 'id' ],

    foreign_keys => [
        payment => {
            class       => 'BOM::Database::AutoGenerated::Rose::Payment',
            key_columns => { payment_id => 'id' },
        },
    ],

    relationships => [
        cryptocurrency_history => {
            class                => 'BOM::Database::AutoGenerated::Rose::CryptocurrencyHistory',
            column_map           => { id => 'id' },
            type                 => 'one to one',
            with_column_triggers => '0',
        },
    ],
);

1;

