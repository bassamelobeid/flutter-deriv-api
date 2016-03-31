SET client_min_messages TO warning;
--BEGIN;

-- -------------------------------------------------------------
-- create ohlc_minutely_insert, which is already created in schema_2_up.sql
-- fix a bug: change table name feed.feed.tablename to feed.tablename
-- -------------------------------------------------------------

CREATE OR REPLACE FUNCTION ohlc_minutely_insert()
RETURNS TRIGGER AS $ohlc_minutely_insert$
DECLARE last_aggregation_time TIMESTAMP;
BEGIN
SELECT last_time INTO last_aggregation_time FROM feed.ohlc_status where underlying=NEW.underlying and type='minute';

IF NEW.ts <> last_aggregation_time THEN
RAISE EXCEPTION 'There was no token for minutely set by tick_insert function. Direct insert into OHLC tables is not allowed to prevent any discrepancy between tick table as main table and its aggregates ohlc tables';
END IF;

-- Update the minutely table
EXECUTE 'INSERT INTO ' || minutely_tablename(NEW.ts) || ' SELECT ($1).*' USING NEW;
RETURN NULL;
END;
$ohlc_minutely_insert$
LANGUAGE plpgsql;
