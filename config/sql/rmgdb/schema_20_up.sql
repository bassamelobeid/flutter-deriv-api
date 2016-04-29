BEGIN;

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SET check_function_bodies = false;
SET client_min_messages = warning;

SET search_path = bet, pg_catalog;

CREATE OR REPLACE FUNCTION ensure_fmb_id_exists()
  RETURNS trigger AS
$BODY$BEGIN
PERFORM id FROM ONLY bet.financial_market_bet WHERE id= NEW.financial_market_bet_id;
IF NOT FOUND THEN RAISE EXCEPTION 'Apparently a matching bet.financial_market_bet.id cannot be found'; END IF;
RETURN NEW;
End;$BODY$
  LANGUAGE plpgsql STABLE
  COST 100;
ALTER FUNCTION ensure_fmb_id_exists()
  OWNER TO postgres;
COMMENT ON FUNCTION bet.ensure_fmb_id_exists() IS 'In order to ensure that we have moved our fmbo record into fmb before deleting it, we are firing an on delete trigger on fmbo that will invoke this function.'; 

/* this will become our parent table for fmb.id values in other tables that require a foreign key for their financial_market_bet_id column */
CREATE TABLE bet.fmbids
(
  id bigint NOT NULL,
  CONSTRAINT fmbids_pkey PRIMARY KEY (id)
)
WITH (
  OIDS=FALSE
);
ALTER TABLE bet.fmbids
  OWNER TO postgres;
GRANT SELECT, UPDATE, INSERT ON TABLE fmbids TO read;
GRANT SELECT, UPDATE, INSERT, DELETE ON TABLE fmbids TO write;
/* there is some question about table permission differences between dev and production, so adding this */
GRANT INSERT ON TABLE fmbids TO insert_on_betonmarkets;

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

/* every new fmb record entering will have it's fmb.id recorded in fmbids */
CREATE OR REPLACE RULE create_fmbids_id AS
    ON INSERT TO financial_market_bet_open DO INSERT INTO fmbids (id)
  VALUES (new.id);

/* this trigger ensures that once we have created an fmb record, it cannot be deleted from the open table until it's entered into fmb as sold */
CREATE CONSTRAINT TRIGGER ensure_fmb_id_before_delete
  AFTER DELETE
  ON financial_market_bet_open
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW
  EXECUTE PROCEDURE ensure_fmb_id_exists();

CREATE INDEX fmbo_account_id_bet_class_idx ON financial_market_bet_open USING btree (account_id, bet_class);

CREATE INDEX fmbo_account_id_purchase_time_bet_class_idx ON financial_market_bet_open USING btree (account_id, date(purchase_time), bet_class);

CREATE INDEX fmbo_account_id_purchase_time_idx ON financial_market_bet_open USING btree (account_id, purchase_time DESC);

CREATE INDEX fmbo_ready_to_sell_idx ON financial_market_bet_open USING btree (expiry_time);

CREATE INDEX fmbo_purchase_time_idx ON financial_market_bet_open USING btree (purchase_time);

/* This next set of statements drops the fkey looking at fmb.id and replaces it with an fkey looking at fmbids. */
ALTER TABLE ONLY digit_bet DROP CONSTRAINT IF EXISTS fk_digit_bet_financial_market_bet_id;
ALTER TABLE digit_bet
  ADD CONSTRAINT fk_digit_bet_financial_market_bet_id FOREIGN KEY (financial_market_bet_id)
      REFERENCES bet.fmbids (id) MATCH SIMPLE
      ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY higher_lower_bet DROP CONSTRAINT IF EXISTS fk_higher_lower_bet_financial_market_bet_id;
ALTER TABLE higher_lower_bet
  ADD CONSTRAINT fk_higher_lower_bet_financial_market_bet_id FOREIGN KEY (financial_market_bet_id)
      REFERENCES bet.fmbids (id) MATCH SIMPLE
      ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY legacy_bet DROP CONSTRAINT IF EXISTS fk_legacy_bet_financial_market_bet_id;
ALTER TABLE legacy_bet
  ADD CONSTRAINT fk_legacy_bet_financial_market_bet_id FOREIGN KEY (financial_market_bet_id)
      REFERENCES bet.fmbids (id) MATCH SIMPLE
      ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY range_bet DROP CONSTRAINT IF EXISTS fk_range_bet_financial_market_bet_id;
ALTER TABLE range_bet
  ADD CONSTRAINT fk_range_bet_financial_market_bet_id FOREIGN KEY (financial_market_bet_id)
      REFERENCES bet.fmbids (id) MATCH SIMPLE
      ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY run_bet DROP CONSTRAINT IF EXISTS fk_run_bet_financial_market_bet_id;
ALTER TABLE run_bet
  ADD CONSTRAINT fk_run_bet_financial_market_bet_id FOREIGN KEY (financial_market_bet_id)
      REFERENCES bet.fmbids (id) MATCH SIMPLE
      ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY bet.spread_bet DROP CONSTRAINT IF EXISTS fk_spread_bet_financial_market_bet_id;
ALTER TABLE spread_bet
  ADD CONSTRAINT fk_spread_bet_financial_market_bet_id FOREIGN KEY (financial_market_bet_id)
      REFERENCES bet.fmbids (id) MATCH SIMPLE
      ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY touch_bet DROP CONSTRAINT IF EXISTS fk_touch_bet_financial_market_bet_id;
ALTER TABLE touch_bet
  ADD CONSTRAINT fk_touch_bet_financial_market_bet_id FOREIGN KEY (financial_market_bet_id)
      REFERENCES bet.fmbids (id) MATCH SIMPLE
      ON UPDATE RESTRICT ON DELETE RESTRICT;
      
SET search_path = data_collection, pg_catalog;

ALTER TABLE quants_bet_variables DROP CONSTRAINT IF EXISTS fk_quants_bet_variables_financial_market_bet_id;
ALTER TABLE quants_bet_variables
  ADD CONSTRAINT fk_quants_bet_variables_financial_market_bet_id FOREIGN KEY (financial_market_bet_id)
      REFERENCES bet.fmbids (id) MATCH SIMPLE
      ON UPDATE RESTRICT ON DELETE RESTRICT;

SET search_path = transaction, pg_catalog;

ALTER TABLE ONLY transaction DROP CONSTRAINT IF EXISTS fk_transaction_financial_market_bet_id;
ALTER TABLE transaction
  ADD CONSTRAINT fk_transaction_financial_market_bet_id FOREIGN KEY (financial_market_bet_id)
      REFERENCES bet.fmbids (id) MATCH SIMPLE
      ON UPDATE RESTRICT ON DELETE RESTRICT;

COMMIT;
