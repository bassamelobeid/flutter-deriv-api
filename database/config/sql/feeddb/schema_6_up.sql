BEGIN;


CREATE OR REPLACE FUNCTION _ohlc_daily_with_open_shift (symbol VARCHAR(128), start_t TIMESTAMP, end_t TIMESTAMP, open_shift INTEGER, limit_n INT DEFAULT null)
RETURNS TABLE (ts_epoch DOUBLE PRECISION, open DOUBLE PRECISION, high DOUBLE PRECISION, low DOUBLE PRECISION, close DOUBLE PRECISION) AS $ohlc_daily_with_open_shift$

    SELECT
        FLOOR( (extract(epoch from ts) + 86400 - $4) / 86400) * 86400 as ts,
        first(open ORDER BY ts) as open,
        max(high) as high,
        min(low) as low,
        last(close ORDER BY ts) as close
    FROM
        feed.ohlc_hourly
    WHERE
        underlying = $1
        AND ts >= $2::timestamp - interval '1 day' + ($4 || ' seconds' )::interval
        AND ts < $3::timestamp + ($4 || ' seconds')::interval
    GROUP BY
        FLOOR( (extract(epoch from ts) + 86400 - $4) / 86400)
    ORDER BY
        ts DESC
    LIMIT $5

$ohlc_daily_with_open_shift$
LANGUAGE sql STABLE;


CREATE OR REPLACE FUNCTION _ohlc_weekly_with_open_shift (symbol VARCHAR(128), start_t TIMESTAMP, end_t TIMESTAMP, open_shift INTEGER, limit_n INT DEFAULT null)
RETURNS TABLE (ts_epoch DOUBLE PRECISION, open DOUBLE PRECISION, high DOUBLE PRECISION, low DOUBLE PRECISION, close DOUBLE PRECISION) AS $ohlc_weekly_with_open_shift$

    WITH daily_ohlc as (
        SELECT
            to_timestamp( FLOOR( (extract(epoch from ts) + 86400 - $4) / 86400) * 86400 ) as ts,
            first(open ORDER BY ts) as open,
            max(high) as high,
            min(low) as low,
            last(close ORDER BY ts) as close
        FROM
            feed.ohlc_hourly
        WHERE
            underlying = $1
            AND ts >= $2::timestamp - interval '1 day' + ($4 || ' seconds')::interval
            AND ts < $3::timestamp + ($4 || ' seconds')::interval + interval '1 week'
        GROUP BY
            FLOOR( (extract(epoch from ts) + 86400 - $4) / 86400)
        ORDER BY
            ts DESC
    )

    SELECT
        extract(epoch from DATE_TRUNC('week', ts)) as ts,
        first(open ORDER BY ts) as open,
        max(high) as high,
        min(low) as low,
        last(close ORDER BY ts) as close
    FROM
        daily_ohlc
    WHERE
        ts >= $2
        AND ts < DATE_TRUNC('week', $3) + interval '1 week'
    GROUP BY
        DATE_TRUNC('week', ts)
    ORDER BY
        ts DESC
    LIMIT $5

$ohlc_weekly_with_open_shift$
LANGUAGE sql STABLE;


CREATE OR REPLACE FUNCTION _ohlc_monthly_with_open_shift (symbol VARCHAR(128), start_t TIMESTAMP, end_t TIMESTAMP, open_shift INTEGER, limit_n INT DEFAULT null)
RETURNS TABLE (ts_epoch DOUBLE PRECISION, open DOUBLE PRECISION, high DOUBLE PRECISION, low DOUBLE PRECISION, close DOUBLE PRECISION) AS $ohlc_monthly_with_open_shift$

    WITH daily_ohlc as (
        SELECT
            to_timestamp( FLOOR( (extract(epoch from ts) + 86400 - $4) / 86400) * 86400 ) as ts,
            first(open ORDER BY ts) as open,
            max(high) as high,
            min(low) as low,
            last(close ORDER BY ts) as close
        FROM
            feed.ohlc_hourly
        WHERE
            underlying = $1
            AND ts >= $2::timestamp - interval '1 day' + ($4 || ' seconds')::interval
            AND ts < $3::timestamp + ($4 || ' seconds')::interval + interval '1 month'
        GROUP BY
            FLOOR( (extract(epoch from ts) + 86400 - $4) / 86400)
        ORDER BY
            ts DESC
    )

    SELECT
        extract(epoch from DATE_TRUNC('month', ts)) as ts,
        first(open ORDER BY ts) as open,
        max(high) as high,
        min(low) as low,
        last(close ORDER BY ts) as close
    FROM
        daily_ohlc
    WHERE
        ts >= $2
        AND ts < DATE_TRUNC('month', $3) + interval '1 month'
    GROUP BY
        DATE_TRUNC('month', ts)
    ORDER BY
        ts DESC
    LIMIT $5

$ohlc_monthly_with_open_shift$
LANGUAGE sql STABLE;


CREATE OR REPLACE FUNCTION _ohlc_irregular_period_with_open_shift (symbol VARCHAR(128), aggregation_period INTEGER, start_t TIMESTAMP, end_t TIMESTAMP, open_shift INTEGER, limit_n INT DEFAULT null)
RETURNS TABLE (ts_epoch DOUBLE PRECISION, open DOUBLE PRECISION, high DOUBLE PRECISION, low DOUBLE PRECISION, close DOUBLE PRECISION) AS $ohlc_irregular_period_with_open_shift$

    WITH daily_ohlc as (
        SELECT
            to_timestamp( FLOOR( (extract(epoch from ts) + 86400 - $5) / 86400) * 86400 ) as ts,
            first(open ORDER BY ts) as open,
            max(high) as high,
            min(low) as low,
            last(close ORDER BY ts) as close
        FROM
            feed.ohlc_hourly
        WHERE
            underlying = $1
            AND ts >= $3::timestamp - interval '1 day' + ($5 || ' seconds')::interval
            AND ts < $4::timestamp + ($5 || ' seconds')::interval + ($2 || ' seconds')::interval
        GROUP BY
            FLOOR( (extract(epoch from ts) + 86400 - $5) / 86400)
        ORDER BY
            ts DESC
    )

    SELECT
        FLOOR(extract(epoch from ts) / $2) * $2 as ts,
        first(open ORDER BY ts) as open,
        max(high) as high,
        min(low) as low,
        last(close ORDER BY ts) as close
    FROM
        daily_ohlc
    WHERE
        ts >= $3
        AND ts < to_timestamp(FLOOR(extract(epoch from $4) / $2) * $2 + $2)
    GROUP BY
        FLOOR(extract(epoch from ts) / $2)
    ORDER BY
        ts DESC
    LIMIT $6

$ohlc_irregular_period_with_open_shift$
LANGUAGE sql STABLE;


DROP FUNCTION _ohlc_start_end_limit (symbol VARCHAR(128), aggregation_period INTEGER, start_t TIMESTAMP, end_t TIMESTAMP, official BOOLEAN, limit_n INT);


CREATE OR REPLACE FUNCTION _ohlc_start_end_limit (symbol VARCHAR(128), aggregation_period INTEGER, start_t TIMESTAMP, end_t TIMESTAMP, official BOOLEAN, limit_n INT DEFAULT null, open_shift INTEGER DEFAULT null)
RETURNS TABLE (ts_epoch DOUBLE PRECISION, open DOUBLE PRECISION, high DOUBLE PRECISION, low DOUBLE PRECISION, close DOUBLE PRECISION) AS $ohlc_start_end$
DECLARE
    sql TEXT;
BEGIN
    PERFORM sanity_checks_start_end(start_t, end_t);

    IF aggregation_period IS NULL THEN
        RAISE EXCEPTION 'Error ohlc_aggregation_function: aggregation_period(%) should be provided', aggregation_period;
    END IF;

    IF open_shift IS NOT NULL AND aggregation_period >= 86400 AND official = FALSE THEN
        IF aggregation_period = 86400 THEN
            RETURN QUERY EXECUTE $$ SELECT * FROM _ohlc_daily_with_open_shift($1, $2, $3, $4, $5) $$ USING symbol, start_t, end_t, open_shift, limit_n;
        ELSIF aggregation_period = 7*24*60*60 THEN
            RETURN QUERY EXECUTE $$ SELECT * FROM _ohlc_weekly_with_open_shift($1, $2, $3, $4, $5) $$ USING symbol, start_t, end_t, open_shift, limit_n;
        ELSIF aggregation_period = 30*24*60*60 THEN
            RETURN QUERY EXECUTE $$ SELECT * FROM _ohlc_monthly_with_open_shift($1, $2, $3, $4, $5) $$ USING symbol, start_t, end_t, open_shift, limit_n;
        ELSE
            RETURN QUERY EXECUTE $$ SELECT * FROM _ohlc_irregular_period_with_open_shift($1, $2, $3, $4, $5, $6) $$ USING symbol, aggregation_period, start_t, end_t, open_shift, limit_n;
        END IF;

        -- RETURN QUERY EXECUTE does not return from function, need explicit return here
        RETURN;
    END IF;

    IF aggregation_period = 60 OR aggregation_period = 60*60 OR aggregation_period = 24*60*60 THEN
        RETURN QUERY EXECUTE $$ SELECT * FROM _ohlc_start_end_fix_periods($1, $2, $3, $4, $5, $6) $$  USING symbol, aggregation_period, start_t, end_t, official, limit_n;
    ELSE
        RETURN QUERY EXECUTE $$ SELECT * FROM _ohlc_start_end_irregular_periods($1, $2, $3, $4, $5, $6) $$  USING symbol, aggregation_period, start_t, end_t, official, limit_n;
    END IF;

END;
$ohlc_start_end$
LANGUAGE plpgsql STABLE;


DROP FUNCTION ohlc_start_end (symbol VARCHAR(128), aggregation_period INTEGER, start_t TIMESTAMP, end_t TIMESTAMP, official BOOLEAN);


CREATE OR REPLACE FUNCTION ohlc_start_end (symbol VARCHAR(128), aggregation_period INTEGER, start_t TIMESTAMP, end_t TIMESTAMP, official BOOLEAN, open_shift INTEGER DEFAULT NULL)
RETURNS TABLE (ts_epoch DOUBLE PRECISION, open DOUBLE PRECISION, high DOUBLE PRECISION, low DOUBLE PRECISION, close DOUBLE PRECISION) AS $ohlc_start_end$

    SELECT * FROM _ohlc_start_end_limit($1, $2, $3, $4, $5, null, $6);

$ohlc_start_end$
LANGUAGE sql STABLE;


DROP FUNCTION ohlc_start_end_with_limit_for_charting (symbol VARCHAR(128), aggregation_period INTEGER, start_t TIMESTAMP, end_t TIMESTAMP, official BOOLEAN, limit_n INT);


CREATE OR REPLACE FUNCTION ohlc_start_end_with_limit_for_charting (symbol VARCHAR(128), aggregation_period INTEGER, start_t TIMESTAMP, end_t TIMESTAMP, official BOOLEAN, limit_n INT DEFAULT null, open_shift INTEGER DEFAULT NULL)
RETURNS TABLE (ts_epoch DOUBLE PRECISION, open DOUBLE PRECISION, high DOUBLE PRECISION, low DOUBLE PRECISION, close DOUBLE PRECISION) AS $ohlc_start_end$

    SELECT * FROM _ohlc_start_end_limit($1, $2, $3, $4, $5, $6, $7);

$ohlc_start_end$
LANGUAGE sql STABLE;


COMMIT;
