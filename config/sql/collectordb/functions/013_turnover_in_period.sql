BEGIN;

CREATE OR REPLACE FUNCTION accounting.turnover_in_period (start_time TIMESTAMP, end_time TIMESTAMP)
RETURNS TABLE (
    accid BIGINT, loginid VARCHAR, currency VARCHAR, name VARCHAR, turnover NUMERIC,
    affiliation BIGINT, affiliate_username TEXT, affiliate_email TEXT
) AS $SQL$

    SELECT
        t.accid,
        t.loginid,
        t.currency,
        t.name,
        t.turnover,
        a.user_id as affiliation,
        a.username as affiliate_username,
        a.email as affiliate_email
    FROM
    (
        SELECT
            accid,
            loginid,
            currency,
            name,
            myaffiliates_token,
            turnover
        FROM
            betonmarkets.production_servers() srv,
            LATERAL dblink(srv.srvname,
            $$
                SELECT * FROM turnover_in_period($$ || quote_literal($1) || $$, $$ || quote_literal($2) || $$)
            $$
            ) AS t(accid BIGINT, loginid VARCHAR, currency VARCHAR, name VARCHAR, myaffiliates_token VARCHAR, turnover NUMERIC)
    ) t

    LEFT JOIN data_collection.myaffiliates_token_details a
        ON a.token = t.myaffiliates_token

$SQL$
LANGUAGE sql STABLE;

COMMIT;
