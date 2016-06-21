BEGIN;

DROP FUNCTION ohlc_daily_list (VARCHAR(128), TIMESTAMP, TIMESTAMP, BOOLEAN);
CREATE OR REPLACE FUNCTION ohlc_daily_list (p_symbol VARCHAR(128), p_start_time TIMESTAMP, p_end_time TIMESTAMP, p_official BOOLEAN)
RETURNS TABLE (ts_epoch DOUBLE PRECISION, open DOUBLE PRECISION, high DOUBLE PRECISION, low DOUBLE PRECISION, close DOUBLE PRECISION) AS $ohlc_daily_list$
DECLARE
    v_ohlc_start TIMESTAMP;
    v_ohlc_end   TIMESTAMP;
BEGIN
    v_ohlc_start := to_timestamp((CEILING(EXTRACT(EPOCH FROM p_start_time)/(60*60*24))*(60*60*24))::INT);
    v_ohlc_end   := to_timestamp((FLOOR((EXTRACT(EPOCH FROM p_end_time)+1)/(60*60*24))*(60*60*24))::INT);

    IF v_ohlc_start < v_ohlc_end THEN
        -- RAISE NOTICE 'v_ohlc_start < v_ohlc_end: %, %', v_ohlc_start, v_ohlc_end;

        RETURN QUERY
            -- part of the first day
            SELECT EXTRACT(EPOCH FROM v_ohlc_start - '1d'::INTERVAL) as ts,
                   (SELECT spot FROM feed.tick WHERE underlying=p_symbol AND p_start_time<=ts AND ts<v_ohlc_start ORDER BY ts ASC LIMIT 1) as open,
                   max(spot) as high,
                   min(spot) as low,
                   (SELECT spot FROM feed.tick WHERE underlying=p_symbol AND p_start_time<=ts AND ts<v_ohlc_start ORDER BY ts DESC LIMIT 1) as close
              FROM feed.tick WHERE underlying=p_symbol AND p_start_time<=ts AND ts<v_ohlc_start
            HAVING max(spot) IS NOT NULL --this eliminates the result row if there are no ticks in the interval

            UNION ALL

            -- complete days
            SELECT EXTRACT(EPOCH FROM ts), o.open, o.high, o.low, o.close
              FROM feed.ohlc_daily o
             WHERE underlying=p_symbol AND v_ohlc_start<=ts AND ts<v_ohlc_end AND official=p_official

            UNION ALL

            -- part of the last day
            SELECT EXTRACT(EPOCH FROM v_ohlc_end) as ts,
                   (SELECT spot FROM feed.tick WHERE underlying=p_symbol AND v_ohlc_end<=ts AND ts<=p_end_time ORDER BY ts ASC LIMIT 1) as open,
                   max(spot) as high,
                   min(spot) as low,
                   (SELECT spot FROM feed.tick WHERE underlying=p_symbol AND v_ohlc_end<=ts AND ts<=p_end_time ORDER BY ts DESC LIMIT 1) as close
              FROM feed.tick WHERE underlying=p_symbol AND v_ohlc_end<=ts AND ts<=p_end_time
            HAVING max(spot) IS NOT NULL

            ORDER BY 1;

    ELSIF v_ohlc_start = v_ohlc_end THEN
        -- RAISE NOTICE 'v_ohlc_start = v_ohlc_end: %, %', v_ohlc_start, v_ohlc_end;

        RETURN QUERY
            -- part of the first day
            SELECT EXTRACT(EPOCH FROM v_ohlc_start - '1d'::INTERVAL) as ts,
                   (SELECT spot FROM feed.tick WHERE underlying=p_symbol AND p_start_time<=ts AND ts<v_ohlc_start ORDER BY ts ASC LIMIT 1) as open,
                   max(spot) as high,
                   min(spot) as low,
                   (SELECT spot FROM feed.tick WHERE underlying=p_symbol AND p_start_time<=ts AND ts<v_ohlc_start ORDER BY ts DESC LIMIT 1) as close
              FROM feed.tick WHERE underlying=p_symbol AND p_start_time<=ts AND ts<v_ohlc_start
            HAVING max(spot) IS NOT NULL

            UNION ALL

            -- part of the last day
            SELECT EXTRACT(EPOCH FROM v_ohlc_end) as ts,
                   (SELECT spot FROM feed.tick WHERE underlying=p_symbol AND v_ohlc_end<=ts AND ts<=p_end_time ORDER BY ts ASC LIMIT 1) as open,
                   max(spot) as high,
                   min(spot) as low,
                   (SELECT spot FROM feed.tick WHERE underlying=p_symbol AND v_ohlc_end<=ts AND ts<=p_end_time ORDER BY ts DESC LIMIT 1) as close
              FROM feed.tick WHERE underlying=p_symbol AND v_ohlc_end<=ts AND ts<=p_end_time
            HAVING max(spot) IS NOT NULL

            ORDER BY 1;

    ELSE -- v_ohlc_start > v_ohlc_end (in fact v_ohlc_start - '1d' = v_ohlc_end)
        -- RAISE NOTICE 'v_ohlc_start > v_ohlc_end: %, %', v_ohlc_start, v_ohlc_end;

        RETURN QUERY
            -- part of the day
            SELECT EXTRACT(EPOCH FROM v_ohlc_end) as ts,
                   (SELECT spot FROM feed.tick WHERE underlying=p_symbol AND p_start_time<=ts AND ts<=p_end_time ORDER BY ts ASC LIMIT 1) as open,
                   max(spot) as high,
                   min(spot) as low,
                   (SELECT spot FROM feed.tick WHERE underlying=p_symbol AND p_start_time<=ts AND ts<=p_end_time ORDER BY ts DESC LIMIT 1) as close
              FROM feed.tick WHERE underlying=p_symbol AND p_start_time<=ts AND ts<=p_end_time
            HAVING max(spot) IS NOT NULL;

    END IF;

END;
$ohlc_daily_list$
LANGUAGE plpgsql STABLE;


COMMENT ON FUNCTION ohlc_daily_list(VARCHAR(16),TIMESTAMP,TIMESTAMP,BOOLEAN) IS
'ohlc_daily_list function will return the OHLC for a period.
start_time, end_time can be anytime in the day. OHLC is the
calculated non-official. For partial days that there is no
OHLC value we will use the child table to find the OHCL values
of that part of day.';

COMMIT;
