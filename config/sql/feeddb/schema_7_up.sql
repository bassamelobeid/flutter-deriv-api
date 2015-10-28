BEGIN;

CREATE OR REPLACE FUNCTION consistent_tick_at_or_before (symbol VARCHAR(16), end_t TIMESTAMP)
RETURNS tick_type AS $consistent_tick_at_or_before$
DECLARE
    end_epoch double precision;
    check_record tick_type;
    result_record tick_type;

BEGIN

    end_epoch := extract(epoch from end_t);
    check_record := tick_after(symbol, end_t);
    result_record := tick_at_or_before(symbol, end_t);

    -- A tick is consistent because it falls directly on the requested time
    -- or we have added ticks after that requested time
    IF check_record.ts_epoch > end_epoch OR result_record.ts_epoch = end_epoch THEN
        RETURN result_record;
    END IF;

    -- Only consistent results can be returned from this function
    RETURN NULL;

END;
$consistent_tick_at_or_before$
LANGUAGE plpgsql STABLE;

COMMIT;
