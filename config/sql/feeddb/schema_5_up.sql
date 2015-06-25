BEGIN;

CREATE TYPE tick_type AS (ts_epoch DOUBLE PRECISION, quote DOUBLE PRECISION, runbet_quote DOUBLE PRECISION, bid DOUBLE PRECISION, ask DOUBLE PRECISION);

------------------------------------------------- Utility Functions - Sanity Checks -------------------------------------------------
-- This is a group of Utility functions to do Sanity Checks
-------------------------------------------------------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION sanity_checks_start_end (start_t TIMESTAMP, end_t TIMESTAMP)
RETURNS void AS $$
BEGIN
    IF start_t IS NULL OR end_t IS NULL THEN
        RAISE EXCEPTION 'Error sanity_checks_start_end: start time(%) and end time(%) should be provided', start_t, end_t;
    ELSIF ( EXTRACT(EPOCH FROM end_t) < EXTRACT(EPOCH FROM start_t) ) THEN
        RAISE EXCEPTION 'Error sanity_checks_start_end: end time(%) < start time(%)',  EXTRACT(EPOCH FROM end_t), EXTRACT(EPOCH FROM start_t);
    END IF;

    RETURN;
END;
$$
LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION sanity_checks_start_limit (start_t TIMESTAMP, limit_count INTEGER)
RETURNS void AS $$
BEGIN
    IF start_t IS NULL OR limit_count IS NULL THEN
        RAISE EXCEPTION 'Error sanity_checks_start_limit: start_t(%) and limit(%) should be provided', start_t, limit_count;
    END IF;

    RETURN;
END;
$$
LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION sanity_checks_end_limit (end_t TIMESTAMP, limit_count INTEGER)
RETURNS void AS $$
BEGIN
    IF end_t IS NULL OR limit_count IS NULL THEN
        RAISE EXCEPTION 'Error sanity_checks_end_limit: end_t(%) and limit(%) should be provided', end_t, limit_count;
    END IF;

    RETURN;
END;
$$
LANGUAGE plpgsql IMMUTABLE;


------------------------------------------------- Function Group : ticks ------------------------------------------------------------
-- This group of functions is used to get raw ticks from the database
-------------------------------------------------------------------------------------------------------------------------------------


CREATE OR REPLACE FUNCTION _ticks_start_end_limit (symbol VARCHAR(128), start_t TIMESTAMP, end_t TIMESTAMP, limit_n INT DEFAULT null)
RETURNS TABLE (ts_epoch DOUBLE PRECISION, quote DOUBLE PRECISION, runbet_quote DOUBLE PRECISION, bid DOUBLE PRECISION, ask DOUBLE PRECISION) AS $ticks_start_end$
BEGIN
    PERFORM sanity_checks_start_end(start_t, end_t);
    RETURN QUERY EXECUTE $$
        SELECT
            EXTRACT(EPOCH FROM ts),
            spot,
            runbet_spot,
            bid,
            ask
        FROM
            feed.tick
        WHERE
            underlying = $1
            AND ts >=$2
            AND ts <= $3
            ORDER BY ts DESC
            LIMIT $4
        $$ USING symbol, start_t, end_t, limit_n;
END;
$ticks_start_end$
LANGUAGE plpgsql STABLE;


CREATE OR REPLACE FUNCTION ticks_start_end (symbol VARCHAR(128), start_t TIMESTAMP, end_t TIMESTAMP)
RETURNS TABLE (ts_epoch DOUBLE PRECISION, quote DOUBLE PRECISION, runbet_quote DOUBLE PRECISION, bid DOUBLE PRECISION, ask DOUBLE PRECISION) AS $ticks_start_end$

    SELECT * FROM _ticks_start_end_limit($1, $2, $3);

$ticks_start_end$
LANGUAGE sql STABLE;


CREATE OR REPLACE FUNCTION ticks_start_end_with_limit_for_charting (symbol VARCHAR(128), start_t TIMESTAMP, end_t TIMESTAMP, limit_count INTEGER)
RETURNS TABLE (ts_epoch DOUBLE PRECISION, quote DOUBLE PRECISION, runbet_quote DOUBLE PRECISION, bid DOUBLE PRECISION, ask DOUBLE PRECISION) AS $ticks_start_end_with_limit_for_charting$

    SELECT * FROM _ticks_start_end_limit($1, $2, $3, $4);

$ticks_start_end_with_limit_for_charting$
LANGUAGE sql STABLE;


CREATE OR REPLACE FUNCTION ticks_start_limit (symbol VARCHAR(128), start_t TIMESTAMP, limit_count INTEGER)
RETURNS TABLE (ts_epoch DOUBLE PRECISION, quote DOUBLE PRECISION, runbet_quote DOUBLE PRECISION, bid DOUBLE PRECISION, ask DOUBLE PRECISION) AS $ticks_start_limit$
BEGIN
    PERFORM sanity_checks_start_limit(start_t, limit_count);

    RETURN QUERY EXECUTE $$ SELECT EXTRACT(EPOCH FROM ts), spot, runbet_spot, bid, ask FROM feed.tick WHERE underlying = $1 and ts >= $2 ORDER BY ts LIMIT $3 $$ USING symbol, start_t, limit_count;
END;
$ticks_start_limit$
LANGUAGE plpgsql STABLE;


CREATE OR REPLACE FUNCTION ticks_end_limit (symbol VARCHAR(128), end_t TIMESTAMP, limit_count INTEGER)
RETURNS TABLE (ts_epoch DOUBLE PRECISION, quote DOUBLE PRECISION, runbet_quote DOUBLE PRECISION, bid DOUBLE PRECISION, ask DOUBLE PRECISION) AS $ticks_end_limit$
BEGIN
    PERFORM sanity_checks_end_limit(end_t, limit_count);
    RETURN QUERY EXECUTE $$ SELECT EXTRACT(EPOCH FROM ts), spot, runbet_spot, bid, ask FROM feed.tick WHERE underlying = $1 and ts <= $2 ORDER BY ts DESC LIMIT $3 $$ USING symbol, end_t, limit_count;
END;
$ticks_end_limit$
LANGUAGE plpgsql STABLE;


------------------------------------------------- Function Group : ohlc ------------------------------------------------------------
-- This group of functions is used to get ohlc from the database
-------------------------------------------------------------------------------------------------------------------------------------


CREATE OR REPLACE FUNCTION _ohlc_start_end_fix_periods (symbol VARCHAR(128), aggregation_period INTEGER, start_t TIMESTAMP, end_t TIMESTAMP, official BOOLEAN, limit_n INT DEFAULT null)
RETURNS TABLE (ts_epoch DOUBLE PRECISION, open DOUBLE PRECISION, high DOUBLE PRECISION, low DOUBLE PRECISION, close DOUBLE PRECISION) AS $ohlc_start_end_fix_periods$

    (
        SELECT
            EXTRACT(EPOCH FROM ts) as ts,
            open,
            high,
            low,
            close
        FROM
            feed.ohlc_minutely
        WHERE
            -- ONLY IF THIS IS A MINUTELY PERIOD
            $2 = 60
            AND underlying = $1
            AND ts >= $3
            AND ts <= $4
        ORDER BY
            ts DESC
        LIMIT $6
    )

    UNION ALL

    (
        SELECT
            EXTRACT(EPOCH FROM ts) as ts,
            open,
            high,
            low,
            close
        FROM
            feed.ohlc_hourly
        WHERE
            -- ONLY IF THIS IS A HOURLY PERIOD
            $2 = 60*60
            AND underlying = $1
            AND ts >= $3
            AND ts <= $4
        ORDER BY
            ts DESC
        LIMIT $6
    )

    UNION ALL

    (
        SELECT
            EXTRACT(EPOCH FROM ts) as ts,
            open,
            high,
            low,
            close
        FROM
            feed.ohlc_daily
        WHERE
            -- ONLY IF THIS IS A DAILY PERIOD
            $2 = 24*60*60
            AND underlying = $1
            AND ts >= $3
            AND ts <= $4
            AND official = $5
        ORDER BY
            ts DESC
        LIMIT $6
    )

$ohlc_start_end_fix_periods$
LANGUAGE sql STABLE;


CREATE OR REPLACE FUNCTION _ohlc_start_end_irregular_periods (symbol VARCHAR(128), aggregation_period INTEGER, start_t TIMESTAMP, end_t TIMESTAMP, official BOOLEAN, limit_n INT DEFAULT null)
RETURNS TABLE (ts_epoch DOUBLE PRECISION, open DOUBLE PRECISION, high DOUBLE PRECISION, low DOUBLE PRECISION, close DOUBLE PRECISION) AS $ohlc_start_end_irregular_periods$

    (
        SELECT
            FLOOR(extract(epoch from ts) / $2) * $2 as ts,
            first(spot ORDER BY ts) as open,
            max(spot) as high,
            min(spot) as low,
            last(spot ORDER BY ts) as close
        FROM
            feed.tick
        WHERE
            $2 < 60
            AND underlying = $1
            AND ts >= $3
            AND ts < to_timestamp(FLOOR(extract(epoch from $4) / $2) * $2 + $2)
        GROUP BY
            FLOOR(extract(epoch from ts) / $2)
        ORDER BY
            ts DESC
        LIMIT $6
    )

    UNION ALL

    (
        SELECT
            FLOOR(extract(epoch from ts) / $2) * $2 as ts,
            first(open ORDER BY ts) as open,
            max(high) as high,
            min(low) as low,
            last(close ORDER BY ts) as close
        FROM
            feed.ohlc_minutely
        WHERE
            $2 > 60 AND $2 < 60*60
            AND underlying = $1
            AND ts >= $3
            AND ts < to_timestamp(FLOOR(extract(epoch from $4) / $2) * $2 + $2)
        GROUP BY
            FLOOR(extract(epoch from ts) / $2)
        ORDER BY
            ts DESC
        LIMIT $6
    )

    UNION ALL

    (
        SELECT
            FLOOR(extract(epoch from ts) / $2) * $2 as ts,
            first(open ORDER BY ts) as open,
            max(high) as high,
            min(low) as low,
            last(close ORDER BY ts) as close
        FROM
            feed.ohlc_hourly
        WHERE
            $2 > 60*60 AND $2 < 24*60*60
            AND underlying = $1
            AND ts >= $3
            AND ts < to_timestamp(FLOOR(extract(epoch from $4) / $2) * $2 + $2)
        GROUP BY
            FLOOR(extract(epoch from ts) / $2)
        ORDER BY
            ts DESC
        LIMIT $6
    )

    UNION ALL

    (
        SELECT
            FLOOR(extract(epoch from ts) / $2) * $2 as ts,
            first(open ORDER BY ts) as open,
            max(high) as high,
            min(low) as low,
            last(close ORDER BY ts) as close
        FROM
            feed.ohlc_daily
        WHERE
            $2 > 24*60*60 AND $2 <> 30*24*60*60 AND $2 <> 7*24*60*60
            AND underlying = $1
            AND ts >= $3
            AND ts < to_timestamp(FLOOR(extract(epoch from $4) / $2) * $2 + $2)
            AND official = $5
        GROUP BY
            FLOOR(extract(epoch from ts) / $2)
        ORDER BY
            ts DESC
        LIMIT $6
    )

    UNION ALL

    (
        SELECT
            extract(epoch from DATE_TRUNC('week', ts)) as ts,
            first(open ORDER BY ts) as open,
            max(high) as high,
            min(low) as low,
            last(close ORDER BY ts) as close
        FROM
            feed.ohlc_daily
        WHERE
            $2 = 7*24*60*60
            AND underlying = $1
            AND ts >= $3
            AND ts < DATE_TRUNC('week', $4) + interval '1 week'
            AND official = $5
        GROUP BY
            DATE_TRUNC('week', ts)
        ORDER BY
            ts DESC
        LIMIT $6
    )

    UNION ALL

    (
        SELECT
            extract(epoch from DATE_TRUNC('month', ts)) as ts,
            first(open ORDER BY ts) as open,
            max(high) as high,
            min(low) as low,
            last(close ORDER BY ts) as close
        FROM
            feed.ohlc_daily
        WHERE
            $2 = 30*24*60*60
            AND underlying = $1
            AND ts >= $3
            AND ts < DATE_TRUNC('month', $4) + interval '1 month'
            AND official = $5
        GROUP BY
            DATE_TRUNC('month', ts)
        ORDER BY
            ts DESC
        LIMIT $6
    )

$ohlc_start_end_irregular_periods$
LANGUAGE sql STABLE;


CREATE OR REPLACE FUNCTION _ohlc_start_end_limit (symbol VARCHAR(128), aggregation_period INTEGER, start_t TIMESTAMP, end_t TIMESTAMP, official BOOLEAN, limit_n INT DEFAULT null)
RETURNS TABLE (ts_epoch DOUBLE PRECISION, open DOUBLE PRECISION, high DOUBLE PRECISION, low DOUBLE PRECISION, close DOUBLE PRECISION) AS $ohlc_start_end$
DECLARE
    sql TEXT;
BEGIN
    PERFORM sanity_checks_start_end(start_t, end_t);

    IF aggregation_period IS NULL THEN
        RAISE EXCEPTION 'Error ohlc_aggregation_function: aggregation_period(%) should be provided', aggregation_period;
    END IF;

    IF aggregation_period = 60 OR aggregation_period = 60*60 OR aggregation_period = 24*60*60 THEN
        RETURN QUERY EXECUTE $$ SELECT * FROM _ohlc_start_end_fix_periods($1, $2, $3, $4, $5, $6) $$  USING symbol, aggregation_period, start_t, end_t, official, limit_n;
    ELSE
        RETURN QUERY EXECUTE $$ SELECT * FROM _ohlc_start_end_irregular_periods($1, $2, $3, $4, $5, $6) $$  USING symbol, aggregation_period, start_t, end_t, official, limit_n;
    END IF;

END;
$ohlc_start_end$
LANGUAGE plpgsql STABLE;


CREATE OR REPLACE FUNCTION ohlc_start_end (symbol VARCHAR(128), aggregation_period INTEGER, start_t TIMESTAMP, end_t TIMESTAMP, official BOOLEAN)
RETURNS TABLE (ts_epoch DOUBLE PRECISION, open DOUBLE PRECISION, high DOUBLE PRECISION, low DOUBLE PRECISION, close DOUBLE PRECISION) AS $ohlc_start_end$

    SELECT * FROM _ohlc_start_end_limit($1, $2, $3, $4, $5, null);

$ohlc_start_end$
LANGUAGE sql STABLE;


CREATE OR REPLACE FUNCTION ohlc_start_end_with_limit_for_charting (symbol VARCHAR(128), aggregation_period INTEGER, start_t TIMESTAMP, end_t TIMESTAMP, official BOOLEAN, limit_n INT DEFAULT null)
RETURNS TABLE (ts_epoch DOUBLE PRECISION, open DOUBLE PRECISION, high DOUBLE PRECISION, low DOUBLE PRECISION, close DOUBLE PRECISION) AS $ohlc_start_end$

    SELECT * FROM _ohlc_start_end_limit($1, $2, $3, $4, $5, $6);

$ohlc_start_end$
LANGUAGE sql STABLE;


------------------------------------------------- Function Group : utility ------------------------------------------------------------
-- These are utility functions used mainly in bet settling
-------------------------------------------------------------------------------------------------------------------------------------


CREATE OR REPLACE FUNCTION tick_after (symbol VARCHAR(16), start_t TIMESTAMP)
RETURNS tick_type AS $tick_after$
DECLARE
    sql TEXT;
    result_record tick_type;
BEGIN

    -- This date is the first table of data we have on production
    IF start_t >= '2011-8-1' THEN
        sql :=  $$
            SELECT
                EXTRACT(EPOCH FROM ts),
                spot,
                runbet_spot,
                bid,
                ask
            FROM
                $$ || tick_tablename(start_t) || $$
            WHERE
                underlying = $1
                AND ts > $2
            ORDER BY ts LIMIT 1
        $$;

        EXECUTE sql INTO result_record USING symbol, start_t;
        IF result_record.quote is not NULL THEN
            RETURN result_record;
        END IF;
    END IF;

    sql :=  $$
        SELECT
            EXTRACT(EPOCH FROM ts),
            spot,
            runbet_spot,
            bid,
            ask
        FROM
            feed.tick
        WHERE
            underlying = $1
            AND ts > $2
        ORDER BY ts LIMIT 1
    $$;

    EXECUTE sql INTO result_record USING symbol, start_t;
    RETURN result_record;

END;
$tick_after$
LANGUAGE plpgsql STABLE;


CREATE OR REPLACE FUNCTION combined_realtime_tick (symbol VARCHAR(16), start_t TIMESTAMP, end_t TIMESTAMP)
RETURNS TABLE (spot DOUBLE PRECISION, epoch DOUBLE PRECISION) AS $combined_realtime_tick$

    SELECT
        last(spot ORDER BY ts) as spot,
        EXTRACT(EPOCH FROM max(ts)) as epoch
    FROM
        feed.tick
    WHERE
        underlying = $1
        AND ts >= $2
        AND ts <= $3

$combined_realtime_tick$
LANGUAGE sql STABLE;


CREATE OR REPLACE FUNCTION ohlc_daily_list (symbol VARCHAR(128), start_time TIMESTAMP, end_time TIMESTAMP, official BOOLEAN)
RETURNS TABLE (ts_epoch DOUBLE PRECISION, open DOUBLE PRECISION, high DOUBLE PRECISION, low DOUBLE PRECISION, close DOUBLE PRECISION) AS $ohlc_daily_list$
DECLARE
    sql TEXT;
    ohlc_start timestamp without time zone;
    ohlc_end timestamp without time zone;
BEGIN
    ohlc_start := to_timestamp((CEILING(EXTRACT(EPOCH FROM start_time)/(60*60*24))*(60*60*24))::INT);
    ohlc_end := to_timestamp((FLOOR((EXTRACT(EPOCH FROM end_time)+1)/(60*60*24))*(60*60*24))::INT);

    sql := $$
    SELECT
        EXTRACT(EPOCH FROM ts) as ts,
        open,
        high,
        low,
        close
    FROM
    (
        SELECT
            date_trunc('day',ts) as ts,
            first(spot ORDER BY ts) as open,
            max(spot) as high,
            min(spot) as low,
            last(spot ORDER BY ts) as close
        FROM
                feed.tick
        WHERE
            underlying=$1
            AND (
                (
                $4 < $5
                AND ( (ts >= $2 AND ts < $4) OR (ts<=$3 AND ts >= $5) )
                )
            OR
                (
                $4 >= $5
                AND ts >= $2
                AND ts<=$3
                )
            )
        GROUP BY
            date_trunc('day',ts)

        UNION

        SELECT
            ts,
            open,
            high,
            low,
            close
        FROM
            feed.ohlc_daily
        WHERE
            underlying=$1
            AND ts>=$4
            AND ts<$5
            AND official=$6
    ) ohlc ORDER BY ts
    $$;

    RETURN QUERY EXECUTE sql USING symbol, start_time, end_time, ohlc_start, ohlc_end, official;

END;
$ohlc_daily_list$
LANGUAGE plpgsql STABLE;


COMMENT ON FUNCTION ohlc_daily_list(VARCHAR(16),TIMESTAMP,TIMESTAMP,BOOLEAN) IS 'ohlc_daily_list function will return the OHLC for a period.start_time, end_time can be anytime in the day. OHLC is the calculated non-official. For partial days that there is no OHLC value we will use the child table to find the OHCL values of that part of day.';


CREATE OR REPLACE FUNCTION tick_at_or_before (symbol VARCHAR(16), end_t TIMESTAMP)
RETURNS tick_type AS $tick_at_or_before$
DECLARE
    sql TEXT;
    result_record tick_type;

BEGIN

    -- This date is the first table of data we have on production
    IF end_t >= '2011-8-1' THEN
        sql := $$
            SELECT
                EXTRACT(EPOCH FROM ts),
                spot,
                runbet_spot,
                bid,
                ask
            FROM
                $$ || tick_tablename(end_t)  || $$
            WHERE
                underlying = $1
                AND ts <= $2
            ORDER BY ts DESC
            LIMIT 1
        $$;

        EXECUTE sql INTO result_record USING symbol, end_t;
        IF result_record.quote is not NULL THEN
            RETURN result_record;
        END IF;
    END IF;

    sql := $$
        SELECT
            EXTRACT(EPOCH FROM ts),
            spot,
            runbet_spot,
            bid,
            ask
        FROM
            feed.tick
        WHERE
            underlying = $1
            AND ts <= $2
        ORDER BY ts DESC
        LIMIT 1
    $$;

    EXECUTE sql INTO result_record USING symbol, end_t;
    RETURN result_record;

END;
$tick_at_or_before$
LANGUAGE plpgsql STABLE;


-- schema 11
CREATE OR REPLACE FUNCTION tick_at_for_interval (symbol VARCHAR(16), start_t TIMESTAMP, end_t TIMESTAMP, interval_time INT)
RETURNS TABLE (ts DOUBLE PRECISION, quote DOUBLE PRECISION, runbet_quote DOUBLE PRECISION, bid DOUBLE PRECISION, ask DOUBLE PRECISION ) AS $tick_at_for_interval$

    SELECT
        ceil((extract('epoch' from ts)) / $4) * $4 as ts,
        last(spot ORDER BY ts) as quote,
        last(runbet_spot ORDER BY ts) as runbet_quote,
        last(bid ORDER BY ts) as bid,
        last(ask ORDER BY ts) as ask
    FROM
        feed.tick
    WHERE
        underlying = $1
        and ts > $2
        and ts <= $3
    GROUP BY
        ceil((extract('epoch' from ts)) / $4) * $4
    ORDER BY
        ts

$tick_at_for_interval$
LANGUAGE sql STABLE;


COMMIT;

