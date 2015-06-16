BEGIN;

CREATE OR REPLACE FUNCTION accounting.get_active_accounts_payment_profit (start_time TIMESTAMP, end_time TIMESTAMP)
RETURNS TABLE (
    account_id BIGINT, loginid VARCHAR, currency VARCHAR, name VARCHAR, usd_payments NUMERIC, usd_profit NUMERIC,
    payments NUMERIC, profit NUMERIC, affiliation BIGINT, affiliate_username TEXT, affiliate_email TEXT
) AS $SQL$

    SELECT
        b.account_id,
        b.loginid,
        b.currency,
        b.name,
        b.usd_payments,
        b.usd_profit,
        b.payments,
        b.profit,
        a.user_id as affiliation,
        a.username as affiliate_username,
        a.email as affiliate_email
    FROM
    (
        SELECT
            account_id,
            loginid,
            currency,
            name,
            myaffiliates_token,
            usd_payments,
            usd_profit,
            payments,
            profit
        FROM
            betonmarkets.production_servers() srv,
            LATERAL dblink(srv.srvname,
            $$
                SELECT * FROM get_active_accounts_payment_profit($$ || quote_literal($1) || $$, $$ || quote_literal($2) || $$)
            $$
            ) AS t(
                account_id BIGINT, loginid VARCHAR, currency VARCHAR, name VARCHAR, myaffiliates_token VARCHAR,
                usd_payments NUMERIC, usd_profit NUMERIC, payments NUMERIC, profit NUMERIC
            )
    ) b

    LEFT JOIN data_collection.myaffiliates_token_details a
        ON a.token = b.myaffiliates_token

$SQL$
LANGUAGE sql STABLE;

COMMIT;
