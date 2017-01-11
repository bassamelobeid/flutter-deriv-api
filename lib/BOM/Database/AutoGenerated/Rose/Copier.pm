package BOM::Database::AutoGenerated::Rose::Copier;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table   => '`copiers`',
    schema  => 'betonmarkets',

    columns => [
        trader_id       => { type => 'varchar', length => 12, not_null => 1 },
        copier_id       => { type => 'varchar', length => 12, not_null => 1 },
        asset           => { type => 'varchar', length => 50 },
        trade_type      => { type => 'varchar', length => 50 },
        min_trade_stake => { type => 'numeric' },
        max_trade_stake => { type => 'numeric' },
    ],

    foreign_keys => [
        client => {
            class       => 'BOM::Database::AutoGenerated::Rose::Client',
            key_columns => { copier_id => 'loginid' },
            rel_type    => 'one to one',
        },

        client_obj => {
            class       => 'BOM::Database::AutoGenerated::Rose::Client',
            key_columns => { trader_id => 'loginid' },
        },
    ],
);

1;

