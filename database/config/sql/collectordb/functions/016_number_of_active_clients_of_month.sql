BEGIN;

CREATE OR REPLACE FUNCTION number_of_active_clients_of_month(start_date TIMESTAMP)
RETURNS TABLE (
    transaction_time NUMERIC, active_clients NUMERIC
) AS $SQL$

    SELECT
        transaction_time,
        sum(active_clients) as active_clients
    FROM
        betonmarkets.production_servers() srv,
        LATERAL dblink(srv.srvname,
        $$

        SELECT
            extract(epoch from tm) AS transaction_time,
            count(DISTINCT a.client_loginid) AS active_clients
        FROM (
              SELECT DISTINCT
                  date_trunc('day', transaction_time) AS tm, account_id
              FROM
                  transaction.transaction t
              WHERE
                      action_type = 'buy'
                  AND transaction_time >= date_trunc('day', $$ || quote_literal($1) || $$::TIMESTAMP)
                  AND transaction_time <  date_trunc('day', $$ || quote_literal($1) || $$::TIMESTAMP) + '1 month'::INTERVAL
             ) t JOIN transaction.account a ON a.id=t.account_id
        GROUP BY tm

        $$
        ) AS t(transaction_time NUMERIC, active_clients BIGINT)
    GROUP BY 1

$SQL$
LANGUAGE sql STABLE;

COMMIT;
