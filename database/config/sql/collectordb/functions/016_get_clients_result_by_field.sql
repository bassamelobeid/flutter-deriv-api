BEGIN;

CREATE OR REPLACE FUNCTION accounting.get_clients_result_by_field (first_name TEXT, last_name TEXT, email TEXT, broker TEXT)
RETURNS TABLE (
    loginid TEXT,
    broker_code TEXT,
    first_name TEXT,
    last_name TEXT,
    email TEXT,
    salutation TEXT,
    phone TEXT,
    fax TEXT,
    address_line_1 TEXT,
    address_line_2 TEXT,
    address_city TEXT,
    address_state TEXT,
    citizen TEXT,
    date_joined TIMESTAMP,
    status_code TEXT,
    last_login TIMESTAMP
) AS $SQL$

    SELECT rem.*
    FROM
        betonmarkets.production_servers(TRUE) s,
        dblink(s.srvname, $$

            WITH client as (
                SELECT
                    loginid,
                    broker_code,
                    first_name,
                    last_name,
                    email,
                    salutation,
                    phone,
                    fax,
                    address_line_1,
                    address_line_2,
                    address_city,
                    address_state,
                    citizen,
                    date_joined
                FROM
                    betonmarkets.client
                WHERE
                    first_name ILIKE $$ || quote_literal($1) || $$
                    AND last_name ILIKE $$ || quote_literal($2) || $$
                    AND email ILIKE $$ || quote_literal($3) || $$
            ),
            status as (
                SELECT
                    client_loginid,
                    string_agg(status_code, ', ') as status_code
                FROM
                    betonmarkets.client_status
                WHERE
                    client_loginid IN (SELECT loginid FROM client)
                    AND status_code IN ('unwelcome', 'cashier_locked', 'disabled', 'withdrawal_locked')
                GROUP BY 1
            ),
            login as (
                SELECT
                    client_loginid,
                    max(login_date) as last_login
                FROM
                    betonmarkets.login_history
                WHERE
                    client_loginid IN (SELECT loginid FROM client)
                    AND login_successful = TRUE
                GROUP BY 1
            )
            SELECT
                loginid,
                broker_code,
                first_name,
                last_name,
                email,
                salutation,
                phone,
                fax,
                address_line_1,
                address_line_2,
                address_city,
                address_state,
                citizen,
                date_joined,
                s.status_code,
                l.last_login
            FROM
                client c
                LEFT JOIN status s
                    ON c.loginid = s.client_loginid
                LEFT JOIN login l
                    ON c.loginid = l.client_loginid

        $$) rem(
            loginid TEXT,
            broker_code TEXT,
            first_name TEXT,
            last_name TEXT,
            email TEXT,
            salutation TEXT,
            phone TEXT,
            fax TEXT,
            address_line_1 TEXT,
            address_line_2 TEXT,
            address_city TEXT,
            address_state TEXT,
            citizen TEXT,
            date_joined TIMESTAMP,
            status_code TEXT,
            last_login TIMESTAMP
        )
    WHERE broker_code LIKE $4

$SQL$
LANGUAGE sql STABLE;

COMMIT;
