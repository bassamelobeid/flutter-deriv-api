BEGIN;
SET search_path = data_collection, pg_catalog;

CREATE OR REPLACE FUNCTION exchangetousd_rate(currency_code character, exchange_date timestamp without time zone DEFAULT now()) RETURNS TABLE(rate numeric)
    LANGUAGE sql STABLE
    AS $_$

    SELECT rate
      FROM data_collection.exchange_rate
     WHERE source_currency = $1
       AND target_currency = 'USD'
       AND date <= $2::TIMESTAMP
  ORDER BY date DESC
     LIMIT 1

$_$;

COMMIT;
