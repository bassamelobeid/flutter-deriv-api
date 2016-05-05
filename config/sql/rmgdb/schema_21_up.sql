/* Note this file was created more or less as a package to split out the current implementation of bet.financial_market_bet (fmb)
 * into an open bets table fmbo and the existing fmb. The corresponding function changes for implementation went into 030_buy_bet and 031_sell_bet.
 */
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
PERFORM id FROM bet.financial_market_bet WHERE id= NEW.financial_market_bet_id;
IF NOT FOUND THEN RAISE EXCEPTION 'Insert failed: Apparently a matching bet.financial_market_bet.id cannot be found'; END IF;
RETURN NEW;
End;$BODY$
  LANGUAGE plpgsql STABLE
  COST 20;
ALTER FUNCTION ensure_fmb_id_exists()
  OWNER TO postgres;
COMMENT ON FUNCTION bet.ensure_fmb_id_exists() IS 'With our open bets going into a transitional table, we cannot employ a conventional foreign key on bet.financial_market_bet (fmb).
However, since that transitional table is a child of fmb, we can check for the existence of a record in fmb to at least ensure that we have a record in place to which this is related.
Since fmb is setup to only accept inserts, we don`t need to create something on that end to handle updates/deletes there.
This trigger function can be used on any table which has a column named financial_market_bet_id referring to bet.financial_market_bet.id'; 

CREATE OR REPLACE FUNCTION ensure_only_fmb_id_exists()
  RETURNS trigger AS
$BODY$BEGIN
PERFORM id FROM ONLY bet.financial_market_bet WHERE id= OLD.id;
IF NOT FOUND THEN RAISE EXCEPTION 'Deletion failied: Apparently a matching bet.financial_market_bet.id cannot be found'; END IF;
RETURN NEW;
End;$BODY$
  LANGUAGE plpgsql STABLE
  COST 20;
ALTER FUNCTION ensure_only_fmb_id_exists()
  OWNER TO postgres;
COMMENT ON FUNCTION bet.ensure_only_fmb_id_exists() IS 'In order to ensure that we have moved our fmbo record into fmb before deleting it, we are firing an on delete trigger on fmbo that will invoke this function.'; 

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

/* this trigger ensures that once we have created an fmb record, it cannot be deleted from the open table until it's entered into fmb as sold */
CREATE CONSTRAINT TRIGGER ensure_fmb_id_before_delete
  AFTER DELETE
  ON financial_market_bet_open
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW
  EXECUTE PROCEDURE ensure_only_fmb_id_exists();

CREATE INDEX fmbo_account_id_bet_class_idx ON financial_market_bet_open USING btree (account_id, bet_class);

CREATE INDEX fmbo_account_id_purchase_time_bet_class_idx ON financial_market_bet_open USING btree (account_id, date(purchase_time), bet_class);

CREATE INDEX fmbo_account_id_purchase_time_idx ON financial_market_bet_open USING btree (account_id, purchase_time DESC);

CREATE INDEX fmbo_ready_to_sell_idx ON financial_market_bet_open USING btree (expiry_time);

CREATE INDEX fmbo_purchase_time_idx ON financial_market_bet_open USING btree (purchase_time);

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

ALTER TABLE ONLY bet.spread_bet DROP CONSTRAINT IF EXISTS fk_spread_bet_financial_market_bet_id;
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

/* Dev boxes do not have these constraints, but they still exist in production and since we will be using this script to deploy, these "drops" are included here.
Since the tables are empty and unused in production, we will not bother to setup the triggers at this time. */
SET search_path = accounting, pg_catalog;

ALTER TABLE ONLY end_of_day_open_positions DROP CONSTRAINT IF EXISTS eod_fmb_fk;
ALTER TABLE ONLY expired_unsold DROP CONSTRAINT IF EXISTS fk_financial_market_bet_id;
ALTER TABLE ONLY realtime_book DROP CONSTRAINT IF EXISTS fk_financial_market_bet_id;

COMMIT;
