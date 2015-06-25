BEGIN;
SET search_path = data_collection, pg_catalog;

CREATE OR REPLACE FUNCTION exchangetousd(amount numeric, currency_code character varying, exchange_date timestamp with time zone DEFAULT now(), for_accounting boolean DEFAULT false, OUT exchanged numeric) RETURNS numeric
    LANGUAGE plpgsql STABLE
    AS $_$
    DECLARE
        search_date timestamp without time zone;
    BEGIN
        IF $4 IS true THEN
            search_date = date_trunc('month', $3 + INTERVAL '1 month');
        ELSE
            search_date = $3 ;
        END IF;

        SELECT INTO exchanged (
            SELECT
                ROUND((rate * $1)::numeric, 4)
            FROM
                data_collection.exchange_rate
            WHERE
                source_currency = $2
                AND target_currency = 'USD'
                AND date <= search_date::timestamp
            ORDER BY
                date DESC
            LIMIT 1
        );
    END;
$_$;

COMMIT;
