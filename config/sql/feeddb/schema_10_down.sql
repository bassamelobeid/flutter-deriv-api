BEGIN;

DROP FUNCTION ohlc_daily_list (VARCHAR(128), TIMESTAMP, TIMESTAMP, BOOLEAN);

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

COMMIT;
