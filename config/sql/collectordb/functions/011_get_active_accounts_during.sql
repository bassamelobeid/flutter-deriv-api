BEGIN;

CREATE OR REPLACE FUNCTION get_active_accounts_during (start_date TIMESTAMP, end_date TIMESTAMP)
RETURNS TABLE (
    id BIGINT, client_loginid VARCHAR, currency_code VARCHAR
) AS $SQL$

    SELECT
        id,
        client_loginid,
        currency_code
    FROM
        betonmarkets.production_servers() srv,
        LATERAL dblink(srv.srvname,
        $$
            SELECT
                id,
                client_loginid,
                currency_code
            FROM
                transaction.account a
            WHERE
                EXISTS (
                    SELECT 1 FROM transaction.transaction WHERE
                        a.id = account_id
                        AND transaction_time >= $$ || quote_literal($1) || $$
                        AND transaction_time < $$ || quote_literal($2) || $$
                )
        $$
        ) AS t(id BIGINT, client_loginid VARCHAR, currency_code VARCHAR)

$SQL$
LANGUAGE sql STABLE;

COMMIT;
