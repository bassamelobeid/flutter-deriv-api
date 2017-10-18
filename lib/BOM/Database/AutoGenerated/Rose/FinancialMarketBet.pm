package BOM::Database::AutoGenerated::Rose::FinancialMarketBet;

use strict;

use base qw(BOM::Database::Rose::DB::Object::AutoBase1);

__PACKAGE__->meta->setup(
    table   => 'financial_market_bet',
    schema   => 'bet',

    columns => [
        id                => { type => 'bigint', not_null => 1, sequence => 'sequences.bet_serial' },
        purchase_time     => { type => 'timestamp', default => 'now()' },
        account_id        => { type => 'bigint', not_null => 1 },
        underlying_symbol => { type => 'varchar', length => 50 },
        payout_price      => { type => 'numeric' },
        buy_price         => { type => 'numeric', not_null => 1 },
        sell_price        => { type => 'numeric' },
        start_time        => { type => 'timestamp' },
        expiry_time       => { type => 'timestamp' },
        settlement_time   => { type => 'timestamp' },
        expiry_daily      => { type => 'boolean', default => 'false', not_null => 1 },
        is_expired        => { type => 'boolean', default => 'false' },
        is_sold           => { type => 'boolean', default => 'false' },
        bet_class         => { type => 'varchar', length => 30, not_null => 1 },
        bet_type          => { type => 'varchar', length => 30, not_null => 1 },
        remark            => { type => 'varchar', length => 800 },
        short_code        => { type => 'varchar', length => 255 },
        sell_time         => { type => 'timestamp' },
        fixed_expiry      => { type => 'boolean' },
        tick_count        => { type => 'integer' },
    ],

    primary_key_columns => [ 'id' ],

    allow_inline_column_values => 1,

    foreign_keys => [
        bet_dictionary => {
            class       => 'BOM::Database::AutoGenerated::Rose::BetDictionary',
            key_columns => { bet_type => 'bet_type' },
        },
    ],

    relationships => [
        coinauction_bet => {
            class      => 'BOM::Database::AutoGenerated::Rose::CoinauctionBet',
            column_map => { id => 'financial_market_bet_id' },
            type       => 'one to one',
        },

        digit_bet => {
            class      => 'BOM::Database::AutoGenerated::Rose::DigitBet',
            column_map => { id => 'financial_market_bet_id' },
            type       => 'one to one',
        },

        higher_lower_bet => {
            class      => 'BOM::Database::AutoGenerated::Rose::HigherLowerBet',
            column_map => { id => 'financial_market_bet_id' },
            type       => 'one to one',
        },

        legacy_bet => {
            class      => 'BOM::Database::AutoGenerated::Rose::LegacyBet',
            column_map => { id => 'financial_market_bet_id' },
            type       => 'one to one',
        },

        lookback_option => {
            class      => 'BOM::Database::AutoGenerated::Rose::LookbackOption',
            column_map => { id => 'financial_market_bet_id' },
            type       => 'one to one',
        },

        range_bet => {
            class      => 'BOM::Database::AutoGenerated::Rose::RangeBet',
            column_map => { id => 'financial_market_bet_id' },
            type       => 'one to one',
        },

        run_bet => {
            class      => 'BOM::Database::AutoGenerated::Rose::RunBet',
            column_map => { id => 'financial_market_bet_id' },
            type       => 'one to one',
        },

        spread_bet => {
            class      => 'BOM::Database::AutoGenerated::Rose::SpreadBet',
            column_map => { id => 'financial_market_bet_id' },
            type       => 'one to one',
        },

        touch_bet => {
            class      => 'BOM::Database::AutoGenerated::Rose::TouchBet',
            column_map => { id => 'financial_market_bet_id' },
            type       => 'one to one',
        },
    ],
);

1;

