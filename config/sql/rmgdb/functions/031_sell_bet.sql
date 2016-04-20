BEGIN;

-- ATTENTION: This function is intended to be used in circumstances when the
-- transaction.account row is already locked for update. The simplest use is
-- something like this:
--
--     WITH acc(account_id) AS (SELECT id
--                                FROM transaction.account
--                               WHERE client_loginid=$1
--                                 AND currency_code=$2
--                                 FOR UPDATE)
--     SELECT *
--       FROM acc
--      CROSS JOIN LATERAL bet_v1.sell_bet(acc.account_id, ...)
--
-- The important piece is the FOR UPDATE clause in the CTE.
--
-- A simpler to use version of the function is available as
--
--     bet_v1.sell_bet(client_loginid, currency_code, ...)
--
-- With that function the account is identified by loginid and currency.

CREATE OR REPLACE FUNCTION bet_v1.sell_bet( p_account_id       BIGINT,                     --  1
                                            p_currency         VARCHAR(3),                 --  2
                                            -- FMB stuff
                                            p_id               BIGINT,                     --  3
                                            p_sell_price       NUMERIC,                    --  4
                                            p_sell_time        TIMESTAMP,                  --  5
                                            p_chld             JSON,                       --  6
                                            -- transaction stuff
                                            p_transaction_time TIMESTAMP,                  --  7
                                            p_staff_loginid    VARCHAR(24),                --  8
                                            p_remark           VARCHAR(800),               --  9
                                            p_source           BIGINT,                     --  10
                                            -- quants_bets_variables
                                            p_qv               JSON,                       -- 11
                                        OUT v_fmb              bet.financial_market_bet,
                                        OUT v_trans            transaction.transaction)
RETURNS SETOF RECORD AS $def$
DECLARE
    v_nrows      INTEGER;
    v_r          RECORD;
BEGIN

    -- It is important that this function is used only in circumstances when the
    -- transaction.account row is already locked FOR UPDATE by the current transaction.
    -- Otherwise, it is prone to deadlock.

    DELETE FROM bet.financial_market_bet_open
     WHERE id=p_id
       AND account_id=p_account_id
    RETURNING * INTO v_fmb;

    GET DIAGNOSTICS v_nrows=ROW_COUNT;
    IF v_nrows>1 THEN
        RAISE EXCEPTION 'FMB Update modifies multiple rows for id=%', p_id;
    ELSIF v_nrows=0 THEN
--        RETURN;
/* This block is necessary until we get all remaining open contracts out of fmb and into fmbo.
 * Once everything in fmb is_sold, then we can remove this block and uncomment the return above. */
    	DELETE FROM bet.financial_market_bet
     	WHERE id=p_id
       		AND account_id=p_account_id
       		AND NOT is_sold
    	RETURNING * INTO v_fmb;

    	GET DIAGNOSTICS v_nrows=ROW_COUNT;
    	IF v_nrows>1 THEN
        	RAISE EXCEPTION 'FMB Update modifies multiple rows for id=%', p_id;
    	ELSIF v_nrows=0 THEN
        	RETURN;
    	END IF;
/* compatibility block */
    END IF;

    -- exactly 1 row modified
    v_fmb.sell_price := p_sell_price;
    v_fmb.sell_time := p_sell_time;
    v_fmb.is_sold := true;
    v_fmb.is_expired := true;
    INSERT INTO bet.financial_market_bet VALUES(v_fmb.*);
    
    IF p_chld IS NOT NULL THEN
        EXECUTE 'UPDATE bet.' || v_fmb.bet_class || ' target SET '
             || (SELECT string_agg(k || ' = r.' || k, ', ') FROM json_object_keys(p_chld) k)
             || '  FROM json_populate_record(NULL::bet.' || v_fmb.bet_class || ', $2) r'
             || ' WHERE target.financial_market_bet_id=$1'
          USING p_id, p_chld;
    END IF;

    PERFORM session_bet_details('sell', v_fmb.id,p_currency, v_fmb.short_code, v_fmb.purchase_time, v_fmb.buy_price, v_fmb.sell_time);

    INSERT INTO transaction.transaction (
        account_id,
        transaction_time,
        amount,
        staff_loginid,
        remark,
        referrer_type,
        financial_market_bet_id,
        action_type,
        quantity,
        source
    ) VALUES (
        p_account_id,
        coalesce(p_transaction_time, now()),
        p_sell_price,
        p_staff_loginid,
        p_remark,
        'financial_market_bet',
        v_fmb.id,
        'sell',
        1,
        p_source
    )
    RETURNING * INTO v_trans;

    IF p_qv IS NOT NULL THEN
        -- this first populates a data_collection.quants_bet_variables record with
        -- the values from q_qv. This record, however, still lacks the fmbid and
        -- transaction_id fields. These are added using a 2nd json_populate_record().
        -- The result of those operations is a complete quants_bet_variables record
        -- which is dereferenced and inserted into the table.
        INSERT INTO data_collection.quants_bet_variables
        SELECT (json_populate_record(tt, ('{"financial_market_bet_id":"' || v_fmb.id || '",'
                                        || '"transaction_id":"' || v_trans.id || '"}')::JSON)).*
          FROM json_populate_record(NULL::data_collection.quants_bet_variables, p_qv) tt;
    END IF;

    RETURN NEXT;
END
$def$ LANGUAGE plpgsql VOLATILE;

COMMIT;
