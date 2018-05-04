package BOM::Database::AutoGenerated::Rose::MarketGlobalRealizedLoss;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table   => 'market_global_realized_loss',
    schema   => 'betonmarkets',

    columns => [
        market         => { type => 'text', not_null => 1 },
        contract_group => { type => 'text', not_null => 1 },
        expiry_type    => { type => 'text', not_null => 1 },
        is_atm         => { type => 'text', not_null => 1 },
        limit_amount   => { type => 'numeric', not_null => 1 },
    ],

    primary_key_columns => [ 'market', 'contract_group', 'expiry_type', 'is_atm' ],
);

1;

