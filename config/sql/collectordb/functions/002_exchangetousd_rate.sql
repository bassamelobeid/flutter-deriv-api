BEGIN;

CREATE OR REPLACE FUNCTION data_collection.exchangetousd_rate(currency_code CHAR(3),
                                                              exchange_date TIMESTAMP DEFAULT now())
RETURNS TABLE(rate NUMERIC)
AS $def$

    SELECT rate
      FROM data_collection.exchange_rate
     WHERE source_currency = $1
       AND target_currency = 'USD'
       AND date <= $2::TIMESTAMP
  ORDER BY date DESC
     LIMIT 1

$def$ LANGUAGE sql STABLE SECURITY invoker;

COMMENT ON FUNCTION data_collection.exchangetousd_rate(currency_code CHAR(3), exchange_date TIMESTAMP)
IS $def$
The function is defined as set-returning while in fact it can return
only one value. With current postgres such a function has better
performance characteristics. Though, that way it cannot be used as
parameter for another function because only a single value is expected
there.

However, best usage, also performance-wise, is to join the function as
if it were a table:

     select sum(round(t.amount * exch.rate, 4))
       from some_table t
  left join exchangetousd_rate(t.currency_code, t.transaction_time) exch(rate)
         on true

This also allows you to use the return value as a function parameter.
$def$;

COMMIT;
