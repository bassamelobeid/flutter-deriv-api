BEGIN;

CREATE OR REPLACE FUNCTION sum_of_bet_txn_of_month(start_date TIMESTAMP)
RETURNS TABLE (
    date DATE, action_type VARCHAR, currency_code VARCHAR, amount NUMERIC
) AS $SQL$

    SELECT
        date,
        action_type,
        currency_code,
        sum(
            CASE
                WHEN action_type = 'buy' THEN -amount
                ELSE amount
            END
        ) AS amount
    FROM
        betonmarkets.production_servers() srv,
        LATERAL dblink(srv.srvname,
        $$

        SELECT
            t.date,
            t.action_type,
            a.currency_code,
            sum(t.amount) AS amount
        FROM (
              SELECT
                  date_trunc('day', transaction_time) AS date,
                  action_type,
                  account_id,
                  sum(amount) as amount
              FROM
                  transaction.transaction
              WHERE
                      transaction_time >= $$ || quote_literal($1) || $$::TIMESTAMP
                  AND transaction_time <  $$ || quote_literal($1) || $$::TIMESTAMP + '1 month'::INTERVAL
                  AND transaction_time <= $$ || (SELECT quote_literal(coalesce(max(calculation_time), now()))
                                                   FROM accounting.realtime_book_archive) || $$::TIMESTAMP
                  AND action_type IN ('buy', 'sell')
              GROUP BY
                  1, 2, 3
             ) t JOIN transaction.account a ON a.id=t.account_id
        GROUP BY
            1, 2, 3

        $$
        ) AS t(date DATE, action_type VARCHAR, currency_code VARCHAR, amount NUMERIC)

    GROUP BY 1,2,3

$SQL$
LANGUAGE sql STABLE;

COMMIT;
