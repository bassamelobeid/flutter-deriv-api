SET client_min_messages TO warning;
--BEGIN;

-- -------------------------------------------------------------
-- Creating tick few common functions used frequently
-- -------------------------------------------------------------


CREATE OR REPLACE FUNCTION tick_tablename (ts TIMESTAMP)
RETURNS TEXT AS $$
BEGIN
   RETURN 'feed.tick_' || DATE_PART('year', ts) || '_' || DATE_PART('month', ts);
END;
$$
LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION minutely_tablename (ts TIMESTAMP)
RETURNS TEXT AS $$
BEGIN
   RETURN 'feed.ohlc_minutely_' || DATE_PART('year', ts);
END;
$$
LANGUAGE plpgsql IMMUTABLE;

-- http://wiki.postgresql.org/wiki/First/last_(aggregate)
-- Create a function that always returns the first non-NULL item
CREATE OR REPLACE FUNCTION public.first_agg ( anyelement, anyelement )
RETURNS anyelement LANGUAGE sql IMMUTABLE STRICT AS $$
        SELECT $1;
$$;

-- And then wrap an aggreagate around it
CREATE AGGREGATE public.first (
        sfunc    = public.first_agg,
        basetype = anyelement,
        stype    = anyelement
);

-- Create a function that always returns the last non-NULL item
CREATE OR REPLACE FUNCTION public.last_agg ( anyelement, anyelement )
RETURNS anyelement LANGUAGE sql IMMUTABLE STRICT AS $$
        SELECT $2;
$$;

-- And then wrap an aggreagate around it
CREATE AGGREGATE public.last (
        sfunc    = public.last_agg,
        basetype = anyelement,
        stype    = anyelement
);

-- -------------------------------------------------------------
-- Creating tick aggregation functions
-- -------------------------------------------------------------

CREATE OR REPLACE FUNCTION insert_ohlc_minute(underlying VARCHAR(128),ts TIMESTAMP)
RETURNS INT AS $insert_ohlc_minute$
BEGIN

    EXECUTE $$
    INSERT INTO feed.ohlc_minutely
    SELECT
        underlying,
        DATE_TRUNC('minute', ts),
        first(spot ORDER BY ts) as open,
        MAX(spot) as high,
        MIN(spot) as low,
        last(spot ORDER BY ts) as close
    FROM
        (
        SELECT
            *
        FROM
            $$ || tick_tablename(ts) || $$
        WHERE
            underlying= $1
            AND ts>= $2  AND ts < $2 + interval '1 minute'
        ORDER by ts
        ) as ordered_list
    GROUP BY underlying, DATE_TRUNC('minute', ts)
    $$ USING underlying, ts;
    RETURN 1;
END;
$insert_ohlc_minute$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION insert_ohlc_hour(underlying VARCHAR(128),ts TIMESTAMP)
RETURNS INT AS $insert_ohlc_hour$
BEGIN

    EXECUTE $$
    INSERT INTO feed.ohlc_hourly
    SELECT
        underlying,
        DATE_TRUNC('hour', ts),
        first(open ORDER BY ts) as open,
        MAX(high) as high,
        MIN(low) as low,
        last(close ORDER BY ts) as close
    FROM
        (
        SELECT
            *
        FROM
                $$ || minutely_tablename(ts) || $$
        WHERE
            underlying= $1
            AND ts>= $2  AND ts < $2 + interval '1 hour'
        ORDER BY ts
        ) as ordered_list
    GROUP BY underlying, DATE_TRUNC('hour', ts)
    $$ USING underlying, ts;
    RETURN 1;
END;
$insert_ohlc_hour$
LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION insert_ohlc_day(underlying VARCHAR(128),ts TIMESTAMP)
RETURNS INT AS $insert_ohlc_day$
BEGIN

    EXECUTE $$
    INSERT INTO feed.ohlc_daily
    SELECT
        underlying,
        DATE_TRUNC('day', ts),
        first(open ORDER BY ts) as open,
        MAX(high) as high,
        MIN(low) as low,
        last(close ORDER BY ts) as close
    FROM
        (
        SELECT
            *
        FROM
            feed.ohlc_hourly
        WHERE
            underlying= $1
            AND ts>= $2  AND ts < $2 + interval '1 day'
        ORDER BY ts
        ) as ordered_list
    GROUP BY underlying, DATE_TRUNC('day', ts)
    $$ USING underlying, ts;
    RETURN 1;
END;
$insert_ohlc_day$
LANGUAGE plpgsql;

-- -------------------------------------------------------------
-- Creating trigger functions for tick and aggregation tables.
-- -------------------------------------------------------------

CREATE OR REPLACE FUNCTION tick_insert()
RETURNS TRIGGER AS $tick_insert$
DECLARE last_tick_ts TIMESTAMP;
DECLARE current_tick_ts_trunc TIMESTAMP;
DECLARE last_aggregation_time TIMESTAMP;
DECLARE last_aggregation_minute TIMESTAMP;
DECLARE table_name VARCHAR(128);
BEGIN
    table_name := tick_tablename(NEW.ts);

    SELECT last_time INTO last_aggregation_time FROM feed.ohlc_status where underlying=NEW.underlying and type='minute';

    -- Get the last tick's ts and make sure we are inserting data in incremental order.
    EXECUTE 'SELECT ts FROM ' || table_name || ' WHERE underlying=$1.underlying ORDER BY ts DESC LIMIT 1' INTO last_tick_ts USING NEW;
    IF (last_tick_ts IS NOT NULL AND NEW.ts <= last_tick_ts) OR (last_aggregation_time IS NOT NULL and last_aggregation_time>=NEW.ts) THEN
        RAISE EXCEPTION 'Could not insert an old tick for [%]', NEW.underlying;
    END IF;

    -- Update the tick table
    EXECUTE 'INSERT INTO ' || table_name || ' SELECT ($1).*' USING NEW;

    current_tick_ts_trunc := DATE_TRUNC('minute', NEW.ts);
    last_aggregation_minute := last_aggregation_time;
    IF current_tick_ts_trunc <> last_aggregation_time THEN
        PERFORM insert_ohlc_minute(NEW.underlying,last_aggregation_time);
    END IF;


    last_aggregation_time := DATE_TRUNC('hour', last_aggregation_time);
    current_tick_ts_trunc := DATE_TRUNC('hour', NEW.ts);
    IF current_tick_ts_trunc <> last_aggregation_time THEN
        PERFORM insert_ohlc_hour(NEW.underlying,last_aggregation_time);
    END IF;

    last_aggregation_time := DATE_TRUNC('day', last_aggregation_time);
    current_tick_ts_trunc := DATE_TRUNC('day', NEW.ts);
    IF current_tick_ts_trunc <> last_aggregation_time THEN
        PERFORM insert_ohlc_day(NEW.underlying,last_aggregation_time);
    END IF;

    current_tick_ts_trunc := DATE_TRUNC('minute', NEW.ts);
    IF last_aggregation_time is NULL THEN
         EXECUTE $$
            INSERT INTO feed.ohlc_status VALUES ($1, $2, 'minute')
        $$ USING NEW.underlying, current_tick_ts_trunc;
    ELSIF current_tick_ts_trunc <> last_aggregation_minute THEN
        UPDATE feed.ohlc_status SET last_time=current_tick_ts_trunc WHERE underlying=NEW.underlying and type='minute';
    END IF;

    PERFORM tick_notify(NEW.underlying,extract('epoch' from NEW.ts)::BIGINT, NEW.spot);

    RETURN NULL;
END;
$tick_insert$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION ohlc_minutely_insert()
RETURNS TRIGGER AS $ohlc_minutely_insert$
DECLARE last_aggregation_time TIMESTAMP;
BEGIN
    SELECT last_time INTO last_aggregation_time FROM feed.ohlc_status where underlying=NEW.underlying and type='minute';

    IF NEW.ts <> last_aggregation_time THEN
       RAISE EXCEPTION 'There was no token for minutely set by tick_insert function. Direct insert into OHLC tables is not allowed to prevent any discrepancy between tick table as main table and its aggregates ohlc tables';
    END IF;

    -- Update the minutely table
    EXECUTE 'INSERT INTO feed.' || minutely_tablename(NEW.ts) || ' SELECT ($1).*' USING NEW;
    RETURN NULL;
END;
$ohlc_minutely_insert$
LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION ohlc_hourly_insert()
RETURNS TRIGGER AS $$
DECLARE last_aggregation_time TIMESTAMP;
BEGIN
    SELECT last_time INTO last_aggregation_time FROM feed.ohlc_status where underlying=NEW.underlying and type='minute';

    last_aggregation_time := DATE_TRUNC('hour', last_aggregation_time);
    IF NEW.ts <> last_aggregation_time THEN
       RAISE EXCEPTION 'There was no token for hourly set by ohlc_minutely_insert function. Direct insert into OHLC tables is not allowed to prevent any discrepancy between tick table as main table and its aggregates ohlc tables';
    END IF;

    RETURN NEW;
END;
$$
LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION ohlc_daily_insert()
RETURNS TRIGGER AS $$
DECLARE last_aggregation_time TIMESTAMP;
BEGIN
    SELECT last_time INTO last_aggregation_time FROM feed.ohlc_status where underlying=NEW.underlying and type='minute';

    last_aggregation_time := DATE_TRUNC('day', last_aggregation_time);
    IF NEW.official <>  true AND NEW.ts <> last_aggregation_time THEN
       RAISE EXCEPTION 'There was no token for hourly set by ohlc_hourly_insert function. Direct insert into OHLC tables is not allowed to prevent any discrepancy between tick table as main table and its aggregates ohlc tables';
    END IF;

    RETURN NEW;
END;
$$
LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION last_tick_time(underlying VARCHAR(128))
RETURNS TIMESTAMP AS $last_tick_time$
DECLARE ts_last TIMESTAMP;
BEGIN
    EXECUTE $$
    SELECT ts FROM feed.tick WHERE underlying = $1 ORDER BY ts DESC LIMIT 1
    $$ INTO ts_last USING underlying;
    RETURN ts_last;
END
$last_tick_time$
LANGUAGE plpgsql;

-- -------------------------------------------------------------
-- Creating triggers for tick and aggregation tables.
-- -------------------------------------------------------------

CREATE TRIGGER tick_insert_trigger
BEFORE INSERT ON feed.tick
FOR EACH ROW EXECUTE PROCEDURE tick_insert();

CREATE TRIGGER ohlc_minutely_insert_trigger
BEFORE INSERT ON feed.ohlc_minutely
FOR EACH ROW EXECUTE PROCEDURE ohlc_minutely_insert();

CREATE TRIGGER ohlc_hourly_insert_trigger
BEFORE INSERT ON feed.ohlc_hourly
FOR EACH ROW EXECUTE PROCEDURE ohlc_hourly_insert();

CREATE TRIGGER ohlc_daily_insert_trigger
BEFORE INSERT ON feed.ohlc_daily
FOR EACH ROW EXECUTE PROCEDURE ohlc_daily_insert();

--COMMIT;
