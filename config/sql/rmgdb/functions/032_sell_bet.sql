BEGIN;

CREATE OR REPLACE FUNCTION bet_v1.sell_bet( a_loginid          VARCHAR(12),                --  1
                                            a_currency         VARCHAR(3),                 --  2
                                            -- FMB stuff
                                            p_id               BIGINT,                     --  3
                                            p_sell_price       NUMERIC,                    --  4
                                            p_sell_time        TIMESTAMP,                  --  5
                                            p_chld             JSON,                       --  6
                                            -- transaction stuff
                                            p_transaction_time TIMESTAMP,                  --  7
                                            p_staff_loginid    VARCHAR(24),                --  8
                                            p_remark           VARCHAR(800),               --  9
                                            p_source           BIGINT,                     -- 10
                                            -- quants_bets_variables
                                            p_qv               JSON,                       -- 11
                                        OUT v_fmb              bet.financial_market_bet,   -- 12
                                        OUT v_trans            transaction.transaction)    -- 13
RETURNS SETOF RECORD AS $def$
DECLARE
    v_r          RECORD;
BEGIN
    -- This query not only fetches the account id. It also works as lock
    -- to prevent deadlocks. It MUST BE THE FIRST QUERY in the function and
    -- it must use FOR UPDATE (instead of FOR NO KEY UPDATE).
    SELECT INTO v_r *
      FROM transaction.account a
     WHERE a.client_loginid=a_loginid
       AND a.currency_code=a_currency
       FOR UPDATE;

    SELECT INTO v_r *
      FROM bet_v1.sell_bet( v_r.id, a_currency, p_id, p_sell_price, p_sell_time, p_chld,
                            p_transaction_time, p_staff_loginid, p_remark, p_source, p_qv);

    IF FOUND THEN
        v_fmb   := v_r.v_fmb;
        v_trans := v_r.v_trans;
        RETURN NEXT;
    END IF;
END
$def$ LANGUAGE plpgsql VOLATILE;

COMMIT;
