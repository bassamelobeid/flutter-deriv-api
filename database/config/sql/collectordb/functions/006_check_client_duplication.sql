BEGIN;

CREATE OR REPLACE FUNCTION check_client_duplication (start_date TIMESTAMP)
RETURNS TABLE (
    new_loginid VARCHAR, first_name VARCHAR, last_name VARCHAR, date_of_birth DATE, loginids TEXT[]
) AS $SQL$

    WITH c AS (
         SELECT rem.*
         FROM
            betonmarkets.production_servers() s,
            dblink(s.srvname, $$

                -- this select returns one row per client. If there is a row in
                -- client_status with status_code either 'ok' or 'disabled'
                -- that status is also returned. 'disabled' has higher precedence.
                -- That means, if there are 2 rows in client_status for a client
                -- one with 'disabled' and the other with 'ok', 'disabled' is
                -- returned.
                SELECT DISTINCT ON(c.loginid)
                    lower(btrim(c.first_name)) AS fn,
                    lower(btrim(c.last_name)) AS ln,
                    c.date_of_birth AS bd,
                    c.loginid,
                    c.date_joined,
                    s.status_code
                FROM betonmarkets.client c
                LEFT JOIN betonmarkets.client_status s
                  ON (c.loginid=s.client_loginid AND s.status_code IN ('ok', 'disabled'))
                LEFT JOIN (VALUES (1::INT, 'disabled'), (2::INT, 'ok')) ord(o, n) ON ord.n=s.status_code
                --WHERE email NOT SIMILAR TO '%@(binary|regentmarkets|betonmarkets).com'
                WHERE reverse(c.email) NOT SIMILAR TO 'moc.(stekramnoteb|stekramtneger|yranib)@%'
                ORDER BY c.loginid, ord.o ASC

            $$) rem(first_name VARCHAR(50),
                    last_name VARCHAR(50),
                    date_of_birth DATE,
                    loginid TEXT,
                    date_joined TIMESTAMP,
                    status_code TEXT)
    )

    SELECT
        x.loginid AS new_loginid,
        t.first_name,
        t.last_name,
        t.date_of_birth,
        t.sloginids AS loginids
    FROM (
        SELECT
            first_name,
            last_name,
            date_of_birth,
            array_agg(loginid) AS loginids,
            array_agg(distinct loginid) AS dloginids,
            array_agg(distinct (loginid || '/' || coalesce(status_code, ''))) AS sloginids
        FROM (
            SELECT first_name, last_name, date_of_birth, loginid, status_code
            FROM c
            WHERE date_joined >= $1

            UNION ALL

            SELECT first_name, last_name, date_of_birth, loginid, status_code
            FROM c
        ) t
        GROUP BY 1,2,3
    ) t
    CROSS JOIN LATERAL (
        SELECT * FROM unnest(t.loginids) l
        EXCEPT ALL
        SELECT * FROM unnest(t.dloginids) d
    ) x(loginid)
    WHERE
        array_upper(t.dloginids, 1) > 1
        AND array_upper(t.loginids, 1) <> array_upper(t.dloginids, 1)

$SQL$
LANGUAGE sql STABLE;

COMMIT;
