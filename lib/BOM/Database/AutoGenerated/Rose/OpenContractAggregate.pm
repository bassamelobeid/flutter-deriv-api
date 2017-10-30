package BOM::Database::AutoGenerated::Rose::OpenContractAggregate;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table   => 'open_contract_aggregates',
    schema   => 'bet',

    columns => [
        currency_code => { type => 'varchar', length => 3, not_null => 1 },
        payout        => { type => 'numeric', not_null => 1 },
        cnt           => { type => 'bigint', not_null => 1 },
        is_aggregate  => { type => 'boolean', default => 'false' },
    ],

    primary_key_columns => [ 'is_aggregate' ],
);

1;

