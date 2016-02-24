BEGIN;

SELECT r.*
  FROM (
    VALUES ('BI004', 'maximum intraday forex turnover limit reached'),
           ('BI005', 'maximum intraday forex potential profit limit reached'),
           ('BI006', 'maximum intraday forex realized profit limit reached')
  ) dat(code, explanation)
CROSS JOIN LATERAL betonmarkets.update_custom_pg_error_code(dat.code, dat.explanation) r;

CREATE OR REPLACE FUNCTION bet_v1.validate_intraday_forex_iv_action(p_account           transaction.account,
                                                                    p_purchase_time     TIMESTAMP,
                                                                    p_buy_price         NUMERIC,
                                                                    p_payout_price      NUMERIC,
                                                                    p_limits            JSON)
RETURNS VOID AS $def$
DECLARE
    v_r RECORD;
BEGIN
    IF (p_limits -> 'intraday_forex_iv_action') IS NOT NULL THEN
        -- this query can be heavy. Should we add an index ... WHERE underlying_symbol LIKE 'frx%' ?
        -- The plan looks like:
        --
        -- Aggregate  (cost=261.98..261.99 rows=1 width=15) (actual time=50.678..50.678 rows=1 loops=1)
        --   Buffers: shared hit=1153
        --   ->  Nested Loop Left Join  (cost=1.57..261.93 rows=4 width=15) (actual time=50.639..50.639 rows=0 loops=1)
        --         Filter: ((COALESCE(t.relative_barrier, h.relative_barrier))::text <> 'S0P'::text)
        --         Buffers: shared hit=1153
        --         ->  Nested Loop Left Join  (cost=1.14..228.08 rows=4 width=27) (actual time=50.638..50.638 rows=0 loops=1)
        --               Buffers: shared hit=1153
        --               ->  Index Scan using financial_market_bet_account_id_purchase_time_bet_class_idx on financial_market_bet b  (cost=0.57..193.71 rows=4 width=23) (actual time=50.637..50.637 rows=0 loops=1)
        --                     Index Cond: ((account_id = 2117141) AND ((purchase_time)::date = (now())::date))
        --                     Filter: (((underlying_symbol)::text ~~ 'frx%'::text) AND ((expiry_time - start_time) < '1 day'::interval))
        --                     Rows Removed by Filter: 1553
        --                     Buffers: shared hit=1153
        --               ->  Index Scan using pk_higher_lower_bet on higher_lower_bet h  (cost=0.56..8.58 rows=1 width=12) (never executed)
        --                     Index Cond: (b.id = financial_market_bet_id)
        --         ->  Index Scan using pk_touch_bet on touch_bet t  (cost=0.43..8.45 rows=1 width=15) (never executed)
        --               Index Cond: (b.id = financial_market_bet_id)
        -- Total runtime: 52.199 ms
        SELECT INTO v_r
               coalesce(sum(buy_price), 0) AS turnover,
               coalesce(sum(CASE WHEN NOT is_sold THEN payout_price-buy_price END), 0) AS potential_profit,
               coalesce(sum(CASE WHEN is_sold THEN sell_price-buy_price END), 0) AS realized_profit
          FROM bet.financial_market_bet b
          LEFT JOIN bet.higher_lower_bet h ON (b.id=h.financial_market_bet_id)
          LEFT JOIN bet.touch_bet t ON (b.id=t.financial_market_bet_id)
         WHERE b.account_id=p_account.id
           AND b.purchase_time::DATE=p_purchase_time::DATE
           AND b.underlying_symbol LIKE 'frx%'
           AND (b.expiry_time - b.start_time) < '1 day'::INTERVAL
           AND coalesce(t.relative_barrier, h.relative_barrier) <> 'S0P';

        IF (v_r.turnover + p_buy_price) > (p_limits -> 'intraday_forex_iv_action' ->> 'turnover')::NUMERIC THEN
            RAISE EXCEPTION USING
                MESSAGE=(SELECT explanation FROM betonmarkets.custom_pg_error_codes WHERE code='BI004'),
                ERRCODE='BI004';
        END IF;

        IF (v_r.potential_profit+p_payout_price-p_buy_price) > (p_limits -> 'intraday_forex_iv_action' ->> 'potential_profit')::NUMERIC THEN
            RAISE EXCEPTION USING
                MESSAGE=(SELECT explanation FROM betonmarkets.custom_pg_error_codes WHERE code='BI005'),
                ERRCODE='BI005';
        END IF;

        IF v_r.realized_profit > (p_limits -> 'intraday_forex_iv_action' ->> 'realized_profit')::NUMERIC THEN
            RAISE EXCEPTION USING
                MESSAGE=(SELECT explanation FROM betonmarkets.custom_pg_error_codes WHERE code='BI006'),
                ERRCODE='BI006';
        END IF;
    END IF;
END
$def$ LANGUAGE plpgsql VOLATILE;

COMMIT;
