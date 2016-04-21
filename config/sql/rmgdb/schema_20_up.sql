BEGIN;

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SET check_function_bodies = false;
SET client_min_messages = warning;

SET search_path = bet, pg_catalog;

/* nickname: fmbo */
CREATE TABLE financial_market_bet_open
(
/* we are inheriting all columns and check constraints from fmb */
  CONSTRAINT fmbo_is_not_sold CHECK (is_sold=FALSE)
)
inherits (bet.financial_market_bet);
ALTER TABLE financial_market_bet_open
  OWNER TO postgres;
GRANT SELECT, UPDATE, INSERT ON TABLE financial_market_bet_open TO read;
GRANT SELECT, UPDATE, INSERT, DELETE ON TABLE financial_market_bet_open TO write;
/* there is some question about table permission differences between dev and production, so adding this */
GRANT INSERT ON TABLE financial_market_bet_open TO insert_on_betonmarkets;

ALTER TABLE ONLY financial_market_bet_open
    ADD CONSTRAINT pk_financial_market_bet_open PRIMARY KEY (id);

ALTER TABLE ONLY financial_market_bet_open
    ADD CONSTRAINT fk_financial_market_bet_open_account_id FOREIGN KEY (account_id) REFERENCES transaction.account(id) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY financial_market_bet_open
    ADD CONSTRAINT fk_fmb_open_bet_type FOREIGN KEY (bet_type) REFERENCES bet_dictionary(bet_type) ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX fmbo_account_id_bet_class_idx ON financial_market_bet_open USING btree (account_id, bet_class);

CREATE INDEX fmbo_account_id_purchase_time_bet_class_idx ON financial_market_bet_open USING btree (account_id, date(purchase_time), bet_class);

CREATE INDEX fmbo_account_id_purchase_time_idx ON financial_market_bet_open USING btree (account_id, purchase_time DESC);

CREATE INDEX fmbo_ready_to_sell_idx ON financial_market_bet_open USING btree (expiry_time);

CREATE INDEX fmbo_purchase_time_idx ON financial_market_bet_open USING btree (purchase_time);

CREATE OR REPLACE FUNCTION ensure_fmb_id_exists()
  RETURNS trigger AS
$BODY$BEGIN
PERFORM id FROM bet.financial_market_bet WHERE id= NEW.financial_market_bet_id;
IF NOT FOUND THEN RAISE EXCEPTION 'Apparently a matching bet.financial_market_bet.id cannot be found'; END IF;
RETURN NEW;
End;$BODY$
  LANGUAGE plpgsql STABLE
  COST 100;
ALTER FUNCTION ensure_fmb_id_exists()
  OWNER TO postgres;
COMMENT ON FUNCTION bet.ensure_fmb_id_exists() IS 'With our open bets going into a transitional table, we cannot employ a conventional foreign key on bet.financial_market_bet (fmb).
However, since that transitional table is a child of fmb, we can check for the existence of a record in fmb to at least ensure that we have a record in place to which this is related.
Since fmb is setup to only accept inserts, we don`t need to create something on that end to handle updates/deletes there.
This trigger function can be used on any table which has a column named financial_market_bet_id referring to bet.financial_market_bet.id'; 

/* this next set of statements drops the fkey looking at fmb.id and replaces it with a check upon record insertion.
 * Ultimately permissions on fmb will deny deletions/updates, addressing those facets of a traditional fkey.
 */
ALTER TABLE ONLY digit_bet DROP CONSTRAINT IF EXISTS fk_digit_bet_financial_market_bet_id;

CREATE TRIGGER trig_ensure_fmb_id_exists
  BEFORE INSERT OR UPDATE
  ON digit_bet
  FOR EACH ROW
  EXECUTE PROCEDURE bet.ensure_fmb_id_exists();
COMMENT ON TRIGGER trig_ensure_fmb_id_exists ON digit_bet IS 'Just a rudimentary check for a related financial_market_bet.id since we cannot use a conventional fkey';

ALTER TABLE ONLY higher_lower_bet DROP CONSTRAINT IF EXISTS fk_higher_lower_bet_financial_market_bet_id;

CREATE TRIGGER trig_ensure_fmb_id_exists
  BEFORE INSERT OR UPDATE
  ON higher_lower_bet
  FOR EACH ROW
  EXECUTE PROCEDURE bet.ensure_fmb_id_exists();
COMMENT ON TRIGGER trig_ensure_fmb_id_exists ON higher_lower_bet IS 'Just a rudimentary check for a related financial_market_bet.id since we cannot use a conventional fkey';

ALTER TABLE ONLY legacy_bet DROP CONSTRAINT IF EXISTS fk_legacy_bet_financial_market_bet_id;

CREATE TRIGGER trig_ensure_fmb_id_exists
  BEFORE INSERT OR UPDATE
  ON legacy_bet
  FOR EACH ROW
  EXECUTE PROCEDURE bet.ensure_fmb_id_exists();
COMMENT ON TRIGGER trig_ensure_fmb_id_exists ON legacy_bet IS 'Just a rudimentary check for a related financial_market_bet.id since we cannot use a conventional fkey';

ALTER TABLE ONLY range_bet DROP CONSTRAINT IF EXISTS fk_range_bet_financial_market_bet_id;

CREATE TRIGGER trig_ensure_fmb_id_exists
  BEFORE INSERT OR UPDATE
  ON range_bet
  FOR EACH ROW
  EXECUTE PROCEDURE bet.ensure_fmb_id_exists();
COMMENT ON TRIGGER trig_ensure_fmb_id_exists ON range_bet IS 'Just a rudimentary check for a related financial_market_bet.id since we cannot use a conventional fkey';

ALTER TABLE ONLY run_bet DROP CONSTRAINT IF EXISTS fk_run_bet_financial_market_bet_id;

CREATE TRIGGER trig_ensure_fmb_id_exists
  BEFORE INSERT OR UPDATE
  ON run_bet
  FOR EACH ROW
  EXECUTE PROCEDURE bet.ensure_fmb_id_exists();
COMMENT ON TRIGGER trig_ensure_fmb_id_exists ON run_bet IS 'Just a rudimentary check for a related financial_market_bet.id since we cannot use a conventional fkey';

ALTER TABLE ONLY bet.spread_bet
    DROP CONSTRAINT IF EXISTS fk_spread_bet_financial_market_bet_id;

CREATE TRIGGER trig_ensure_fmb_id_exists
  BEFORE INSERT OR UPDATE
  ON bet.spread_bet
  FOR EACH ROW
  EXECUTE PROCEDURE bet.ensure_fmb_id_exists();
COMMENT ON TRIGGER trig_ensure_fmb_id_exists ON bet.spread_bet IS 'Just a rudimentary check for a related financial_market_bet.id since we cannot use a conventional fkey';

ALTER TABLE ONLY touch_bet DROP CONSTRAINT IF EXISTS fk_touch_bet_financial_market_bet_id;

CREATE TRIGGER trig_ensure_fmb_id_exists
  BEFORE INSERT OR UPDATE
  ON touch_bet
  FOR EACH ROW
  EXECUTE PROCEDURE bet.ensure_fmb_id_exists();
COMMENT ON TRIGGER trig_ensure_fmb_id_exists ON touch_bet IS 'Just a rudimentary check for a related financial_market_bet.id since we cannot use a conventional fkey';

SET search_path = data_collection, pg_catalog;

ALTER TABLE quants_bet_variables DROP CONSTRAINT IF EXISTS fk_quants_bet_variables_financial_market_bet_id;

CREATE TRIGGER trig_ensure_fmb_id_exists
  BEFORE INSERT OR UPDATE
  ON quants_bet_variables
  FOR EACH ROW
  EXECUTE PROCEDURE bet.ensure_fmb_id_exists();
COMMENT ON TRIGGER trig_ensure_fmb_id_exists ON quants_bet_variables IS 'Just a rudimentary check for a related financial_market_bet.id since we cannot use a conventional fkey';

SET search_path = transaction, pg_catalog;

ALTER TABLE ONLY transaction DROP CONSTRAINT IF EXISTS fk_transaction_financial_market_bet_id;

CREATE TRIGGER trig_ensure_fmb_id_exists
  BEFORE INSERT OR UPDATE
  ON transaction
  FOR EACH ROW
  WHEN ((new.financial_market_bet_id IS NOT NULL))
  EXECUTE PROCEDURE bet.ensure_fmb_id_exists();
COMMENT ON TRIGGER trig_ensure_fmb_id_exists ON transaction IS 'Just a rudimentary check for a related financial_market_bet.id since we cannot use a conventional fkey';

/* Modify our buy_bet func to insert into fmbo instead of fmb */
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

/* Modify our sell_bet func to move unsold bets from fmbo into fmb as sold bets.
 * Note this revision also contains a compatibility mode to deal with residual unsold bets already existing in fmb.
 * After a day or so of selling very short term bets (< 1 day), we will actually move all remaining unsold bets from fmb into fmbo.
 * At that point, compatibility mode will be removed and final permissions will be set on fmb to only allow inserts.
 */
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
