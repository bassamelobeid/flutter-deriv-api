BEGIN;

CREATE OR REPLACE FUNCTION data_collection.exchangetousd(amount NUMERIC,
                                                         currency_code VARCHAR(3),
                                                         exchange_date TIMESTAMPTZ DEFAULT now(),
                                                         for_accounting BOOLEAN DEFAULT false)
RETURNS NUMERIC
AS $def$

    SELECT ROUND((rate * $1)::NUMERIC, 4)
      FROM data_collection.exchange_rate
     WHERE source_currency = $2
       AND target_currency = 'USD'
       AND (    $4 AND date <= date_trunc('month', $3 + INTERVAL '1 month')::TIMESTAMP OR
            NOT $4 AND date <= $3::TIMESTAMP)
  ORDER BY date DESC
     LIMIT 1

$def$ LANGUAGE sql STABLE SECURITY invoker;

COMMIT;
