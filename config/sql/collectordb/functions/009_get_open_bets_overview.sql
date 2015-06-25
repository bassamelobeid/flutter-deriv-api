BEGIN;

CREATE OR REPLACE FUNCTION accounting.get_open_bets_overview ()
RETURNS TABLE (
    account_id BIGINT, loginid VARCHAR, currency_code VARCHAR, id BIGINT, buy_price NUMERIC, expiry_time TIMESTAMP, payout_price NUMERIC,
    short_code VARCHAR, name VARCHAR, market_price NUMERIC, percentage_change NUMERIC, ref BIGINT,
    affiliation BIGINT, affiliate_username TEXT, affiliate_email TEXT
) AS $SQL$

    SELECT
        b.account_id,
        b.loginid,
        b.currency_code,
        b.id,
        b.buy_price,
        b.expiry_time,
        b.payout_price,
        b.short_code,
        b.name,
        b.market_price,
        b.percentage_change,
        b.ref,
        a.user_id as affiliation,
        a.username as affiliate_username,
        a.email as affiliate_email
    FROM
    (
        SELECT
            account_id,
            loginid,
            currency_code,
            id,
            buy_price,
            expiry_time,
            payout_price,
            short_code,
            name,
            myaffiliates_token,
            market_price,
            percentage_change,
            ref
        FROM
            betonmarkets.production_servers() srv,
            LATERAL dblink(srv.srvname,
            $$
                SELECT * FROM get_open_bets_overview()
            $$
            ) AS t(account_id BIGINT, loginid VARCHAR, currency_code VARCHAR, id BIGINT, buy_price NUMERIC, expiry_time TIMESTAMP, payout_price NUMERIC, short_code VARCHAR, name VARCHAR, myaffiliates_token VARCHAR, market_price NUMERIC, percentage_change NUMERIC, ref BIGINT)
    ) b

    LEFT JOIN data_collection.myaffiliates_token_details a
        ON b.myaffiliates_token = a.token

$SQL$
LANGUAGE sql STABLE;

COMMIT;
