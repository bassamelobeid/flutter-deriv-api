package BOM::Database::AutoGenerated::Rose::MyaffiliatesCommission;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table   => 'myaffiliates_commission',
    schema   => 'data_collection',

    columns => [
        id                           => { type => 'bigint', not_null => 1, sequence => 'sequences.global_serial' },
        affiliate_userid             => { type => 'bigint' },
        affiliate_username           => { type => 'text' },
        effective_date               => { type => 'date' },
        intraday_turnover            => { type => 'numeric', precision => 2, scale => 20 },
        runbet_turnover              => { type => 'numeric', precision => 2, scale => 20 },
        other_turnover               => { type => 'numeric', precision => 2, scale => 20 },
        pnl                          => { type => 'numeric', precision => 2, scale => 20 },
        effective_pnl_for_commission => { type => 'numeric', precision => 2, scale => 20 },
        carry_over_to_next_month     => { type => 'numeric', precision => 2, scale => 20 },
        commission                   => { type => 'numeric', precision => 2, scale => 20 },
    ],

    primary_key_columns => [ 'id' ],

    unique_key => [ 'affiliate_userid', 'affiliate_username', 'effective_date' ],
);

1;

