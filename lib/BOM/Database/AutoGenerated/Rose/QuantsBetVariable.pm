package BOM::Database::AutoGenerated::Rose::QuantsBetVariable;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table   => 'quants_bet_variables',
    schema   => 'data_collection',

    columns => [
        financial_market_bet_id => { type => 'bigint', not_null => 1 },
        theo                    => { type => 'numeric' },
        trade                   => { type => 'numeric' },
        recalc                  => { type => 'numeric' },
        iv                      => { type => 'numeric' },
        win                     => { type => 'numeric' },
        delta                   => { type => 'numeric' },
        vega                    => { type => 'numeric' },
        theta                   => { type => 'numeric' },
        gamma                   => { type => 'numeric' },
        intradaytime            => { type => 'numeric' },
        div                     => { type => 'numeric' },
        int                     => { type => 'numeric' },
        base_spread             => { type => 'numeric' },
        news_fct                => { type => 'numeric' },
        mrev_fct                => { type => 'numeric' },
        mrv_ind                 => { type => 'numeric' },
        fwdst_fct               => { type => 'numeric' },
        atmf_fct                => { type => 'numeric' },
        dscrt_fct               => { type => 'numeric' },
        spot                    => { type => 'numeric' },
        emp                     => { type => 'numeric' },
        transaction_id          => { type => 'bigint', not_null => 1 },
        entry_spot              => { type => 'numeric' },
        entry_spot_epoch        => { type => 'bigint' },
        exit_spot               => { type => 'numeric' },
        exit_spot_epoch         => { type => 'bigint' },
        price_slippage          => { type => 'numeric' },
        requested_price         => { type => 'numeric'},
        recomputed_price        => { type => 'numeric'},
        trading_period_start    => { type => 'timestamp' },
    ],

    primary_key_columns => [ 'transaction_id' ],
);

1;

