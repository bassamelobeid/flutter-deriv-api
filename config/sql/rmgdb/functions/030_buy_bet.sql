BEGIN;

CREATE OR REPLACE FUNCTION session_bet_details (
    action_type VARCHAR(10),
    fmb_id bigint,
    currency_code VARCHAR(3),
    short_code VARCHAR(255),
    purchase_time TIMESTAMP,
    purchase_price NUMERIC,
    sell_time TIMESTAMP
) RETURNS VOID AS $def$
BEGIN
    CREATE TEMPORARY TABLE IF NOT EXISTS session_bet_details (
        action_type  VARCHAR(10),
        fmb_id bigint,
        currency_code VARCHAR(3),
        short_code VARCHAR(255),
        purchase_time TIMESTAMP,
        purchase_price NUMERIC,
        sell_time TIMESTAMP
    ) ON COMMIT DROP;
    INSERT INTO session_bet_details VALUES (action_type,fmb_id,currency_code,short_code,purchase_time,purchase_price,sell_time);
END
$def$ LANGUAGE plpgsql VOLATILE SECURITY INVOKER;

CREATE OR REPLACE FUNCTION bet_v1.buy_bet(  a_loginid           VARCHAR(12),    --  1
                                            a_currency          VARCHAR(3),     --  2
                                            -- FMB stuff
                                            b_purchase_time     TIMESTAMP,      --  3
                                            b_underlying_symbol VARCHAR(50),    --  4
                                            b_payout_price      NUMERIC,        --  5
                                            b_buy_price         NUMERIC,        --  6
                                            b_start_time        TIMESTAMP,      --  7
                                            b_expiry_time       TIMESTAMP,      --  8
                                            b_settlement_time   TIMESTAMP,      --  9
                                            b_expiry_daily      BOOLEAN,        -- 10
                                            b_bet_class         VARCHAR(30),    -- 11
                                            b_bet_type          VARCHAR(30),    -- 12
                                            b_remark            VARCHAR(800),   -- 13
                                            b_short_code        VARCHAR(255),   -- 14
                                            b_fixed_expiry      BOOLEAN,        -- 15
                                            b_tick_count        INT,            -- 16
                                            -- fmb child table
                                            b_chld              JSON,           -- 17
                                            -- transaction stuff
                                            t_transaction_time  TIMESTAMP,      -- 18
                                            t_staff_loginid     VARCHAR(24),    -- 19
                                            t_remark            VARCHAR(800),   -- 20
                                            t_source            BIGINT,         -- 21
                                            -- quants_bets_variables
                                            q_qv                JSON,           -- 22
                                            p_limits            JSON,           -- 23
                                        OUT v_fmb               bet.financial_market_bet,
                                        OUT v_trans             transaction.transaction)
RETURNS SETOF RECORD AS $def$
DECLARE
    v_account          transaction.account;
BEGIN
    SELECT * INTO v_account
      FROM bet_v1.validate_balance_and_lock_account(a_loginid, a_currency,
                                                    b_buy_price);

    PERFORM bet_v1.validate_max_balance(v_account, p_limits),
            bet_v1.validate_max_open_bets_and_payout(v_account, b_underlying_symbol,
                                                     b_bet_type, b_payout_price, p_limits),
            bet_v1.validate_specific_turnover_limits(v_account,
                                                     b_purchase_time, b_buy_price, p_limits),
            bet_v1.validate_7day_limits(v_account,
                                        b_purchase_time, b_buy_price, p_limits),
            bet_v1.validate_30day_limits(v_account,
                                         b_purchase_time, b_buy_price, p_limits),
            bet_v1.validate_intraday_forex_iv_action(v_account, b_purchase_time,
                                                     b_buy_price, b_payout_price, p_limits),
            bet_v1.validate_spreads_daily_profit_limit( v_account, b_purchase_time,
                                                        b_chld, p_limits);

    RESET log_min_messages;

    INSERT INTO bet.financial_market_bet_open (
        purchase_time,
        account_id,
        underlying_symbol,
        payout_price,
        buy_price,
        start_time,
        expiry_time,
        settlement_time,
        expiry_daily,
        bet_class,
        bet_type,
        remark,
        short_code,
        fixed_expiry,
        tick_count
    ) VALUES (
        b_purchase_time,
        v_account.id,
        b_underlying_symbol,
        b_payout_price,
        b_buy_price,
        b_start_time,
        b_expiry_time,
        b_settlement_time,
        b_expiry_daily,
        b_bet_class,
        b_bet_type,
        b_remark,
        b_short_code,
        b_fixed_expiry,
        b_tick_count
    )
    RETURNING * INTO v_fmb;

    EXECUTE $$
        INSERT INTO bet.$$ || b_bet_class || $$
        SELECT (json_populate_record(tt, ('{"financial_market_bet_id":"' || $1 || '"}')::JSON)).*
          FROM json_populate_record(NULL::bet.$$ || b_bet_class || $$, $2) tt
    $$ USING v_fmb.id, b_chld;

    PERFORM session_bet_details('buy', v_fmb.id, a_currency, b_short_code, b_purchase_time, b_buy_price, NULL);

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
        v_account.id,
        coalesce(t_transaction_time, now()),
        -1 * b_buy_price,
        t_staff_loginid,
        t_remark,
        'financial_market_bet',
        v_fmb.id,
        'buy',
        1,
        t_source
    )
    RETURNING * INTO v_trans;

    IF q_qv IS NOT NULL THEN
        -- this first populates a data_collection.quants_bet_variables record with
        -- the values from q_qv. This record, however, still lacks the fmbid and
        -- transaction_id fields. These are added using a 2nd json_populate_record().
        -- The result of those operations is a complete quants_bet_variables record
        -- which is dereferenced and inserted into the table.
        INSERT INTO data_collection.quants_bet_variables
        SELECT (json_populate_record(tt, ('{"financial_market_bet_id":"' || v_fmb.id || '",'
                                        || '"transaction_id":"' || v_trans.id || '"}')::JSON)).*
          FROM json_populate_record(NULL::data_collection.quants_bet_variables, q_qv) tt;

    END IF;

    RETURN NEXT;
END
$def$ LANGUAGE plpgsql VOLATILE SECURITY definer SET log_min_messages = LOG;

CREATE OR REPLACE FUNCTION bet_v1.buy_bet_nofail(   a_loginid           VARCHAR(12),    --  1
                                                    a_currency          VARCHAR(3),     --  2
                                                    -- FMB stuff
                                                    b_purchase_time     TIMESTAMP,      --  3
                                                    b_underlying_symbol VARCHAR(50),    --  4
                                                    b_payout_price      NUMERIC,        --  5
                                                    b_buy_price         NUMERIC,        --  6
                                                    b_start_time        TIMESTAMP,      --  7
                                                    b_expiry_time       TIMESTAMP,      --  8
                                                    b_settlement_time   TIMESTAMP,      --  9
                                                    b_expiry_daily      BOOLEAN,        -- 10
                                                    b_bet_class         VARCHAR(30),    -- 11
                                                    b_bet_type          VARCHAR(30),    -- 12
                                                    b_remark            VARCHAR(800),   -- 13
                                                    b_short_code        VARCHAR(255),   -- 14
                                                    b_fixed_expiry      BOOLEAN,        -- 15
                                                    b_tick_count        INT,            -- 16
                                                    -- fmb child table
                                                    b_chld              JSON,           -- 17
                                                    -- transaction stuff
                                                    t_transaction_time  TIMESTAMP,      -- 18
                                                    t_staff_loginid     VARCHAR(24),    -- 19
                                                    t_remark            VARCHAR(800),   -- 20
                                                    t_source            BIGINT,         -- 21
                                                    -- quants_bets_variables
                                                    q_qv                JSON,           -- 22
                                                    p_limits            JSON,           -- 23
                                                OUT r_fmb               bet.financial_market_bet,
                                                OUT r_trans             transaction.transaction,
                                                OUT r_ecode             TEXT,
                                                OUT r_edescription      TEXT)
RETURNS SETOF RECORD AS $def$
DECLARE
    v_r                RECORD;
BEGIN
    BEGIN
        SELECT * INTO v_r
          FROM bet_v1.buy_bet(  a_loginid,
                                a_currency,
                                -- FMB stuff
                                b_purchase_time,
                                b_underlying_symbol,
                                b_payout_price,
                                b_buy_price,
                                b_start_time,
                                b_expiry_time,
                                b_settlement_time,
                                b_expiry_daily,
                                b_bet_class,
                                b_bet_type,
                                b_remark,
                                b_short_code,
                                b_fixed_expiry,
                                b_tick_count,
                                -- fmb child table
                                b_chld,
                                -- transaction stuff
                                t_transaction_time,
                                t_staff_loginid,
                                t_remark,
                                t_source,
                                -- quants_bets_variables
                                q_qv,
                                p_limits) t;
        r_fmb := v_r.v_fmb;
        r_trans := v_r.v_trans;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS r_ecode = RETURNED_SQLSTATE,
                                r_edescription = MESSAGE_TEXT;
    END;
    RETURN NEXT;
END
$def$ LANGUAGE plpgsql VOLATILE SECURITY invoker;

COMMIT;
