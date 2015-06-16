BEGIN;

SELECT r.*
  FROM (
    VALUES ('BI002', 'maximum self-exclusion number of open contracts exceeded')
  ) dat(code, explanation)
CROSS JOIN LATERAL betonmarkets.update_custom_pg_error_code(dat.code, dat.explanation) r;

CREATE OR REPLACE FUNCTION bet.validate_max_open_bets(p_loginid VARCHAR(12),
                                                      p_limits  JSON)
RETURNS VOID AS $def$
DECLARE
    v_n BIGINT;
BEGIN
    IF (p_limits -> 'max_open_bets') IS NOT NULL THEN
        -- The plan is supposed to look like:
        --
        -- Aggregate  (cost=25.48..25.49 rows=1 width=0) (actual time=7.967..7.967 rows=1 loops=1)
        --    Buffers: shared hit=46
        --    InitPlan 1 (returns $0)
        --      ->  Index Scan using pk_account on account a2  (cost=0.42..8.44 rows=1 width=8) (actual time=0.319..0.357 rows=1 loops=1)
        --            Index Cond: (id = 2117141)
        --            Buffers: shared hit=4
        --    ->  Nested Loop  (cost=0.99..17.04 rows=1 width=0) (actual time=2.521..7.770 rows=23 loops=1)
        --          Buffers: shared hit=46
        --          ->  Index Scan using uk_account_client_loginid_currency_code on account a  (cost=0.42..8.44 rows=1 width=8) (actual time=1.002..1.003 rows=1 loops=1)
        --                Index Cond: ((client_loginid)::text = ($0)::text)
        --                Buffers: shared hit=8
        --          ->  Index Only Scan using financial_market_bet_account_id_is_sold_bet_class_idx on financial_market_bet b  (cost=0.57..8.59 rows=1 width=8) (actual time=1.441..6.604 rows=23 loops=1)
        --                Index Cond: ((account_id = a.id) AND (is_sold = false))
        --                Filter: (NOT is_sold)
        --                Heap Fetches: 30
        --                Buffers: shared hit=38
        --  Total runtime: 9.009 ms
        SELECT INTO v_n count(*)
          FROM bet.financial_market_bet b
          JOIN transaction.account a ON b.account_id=a.id
         WHERE a.client_loginid=p_loginid
           AND NOT b.is_sold;

        IF v_n+1 > (p_limits ->> 'max_open_bets')::BIGINT THEN
            RAISE EXCEPTION USING
                MESSAGE=(SELECT explanation FROM betonmarkets.custom_pg_error_codes WHERE code='BI002'),
                ERRCODE='BI002';
        END IF;
    END IF;
END
$def$ LANGUAGE plpgsql VOLATILE;

COMMIT;
