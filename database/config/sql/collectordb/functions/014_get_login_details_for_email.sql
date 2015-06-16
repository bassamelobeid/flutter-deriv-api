BEGIN;

CREATE OR REPLACE FUNCTION get_login_details_for_email (email VARCHAR)
RETURNS TABLE (
    loginid VARCHAR, broker_code VARCHAR, email VARCHAR
) AS $SQL$

    SELECT
        loginid,
        broker_code,
        email
    FROM
        betonmarkets.production_servers(TRUE) srv,
        LATERAL dblink(srv.srvname,
        $$
            SELECT
                loginid,
                broker_code,
                email
            FROM
                betonmarkets.client c
            WHERE
                email ILIKE $$ || quote_literal($1) || $$
                AND NOT EXISTS (
                    SELECT 1 FROM betonmarkets.client_status
                    WHERE
                        client_loginid = c.loginid
                        AND status_code = 'disabled'
                )
        $$
        ) AS t(loginid VARCHAR, broker_code VARCHAR, email VARCHAR)

$SQL$
LANGUAGE sql STABLE;

COMMIT;
