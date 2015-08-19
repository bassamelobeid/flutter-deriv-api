SET statement_timeout = 0;

BEGIN;

UPDATE bet.financial_market_bet fmb
    SET expiry_time = start_time::timestamp + interval '365 days',
        settlement_time = start_time::timestamp + interval '365 days',
        payout_price = (
            SELECT
                CASE
                    WHEN chld.stop_type='dollar' THEN chld.stop_profit
                    WHEN chld.stop_type='point' THEN chld.stop_profit * chld.amount_per_point
                END
            FROM bet.spread_bet chld
            WHERE fmb.id = chld.financial_market_bet_id
        )
    WHERE bet_class='spread_bet'
        AND expiry_time IS NULL
        AND payout_price IS NULL
        AND is_sold IS TRUE;

COMMIT;

BEGIN;

UPDATE bet.financial_market_bet fmb
    SET expiry_time = start_time::timestamp + interval '365 days',
        settlement_time = start_time::timestamp + interval '365 days',
        payout_price = (
            SELECT
                CASE
                    WHEN chld.stop_type='dollar' THEN chld.stop_profit
                    WHEN chld.stop_type='point' THEN chld.stop_profit * chld.amount_per_point
                END
            FROM bet.spread_bet chld
            WHERE fmb.id = chld.financial_market_bet_id
        )
    WHERE bet_class='spread_bet'
        AND expiry_time IS NULL
        AND payout_price IS NULL;

COMMIT;
