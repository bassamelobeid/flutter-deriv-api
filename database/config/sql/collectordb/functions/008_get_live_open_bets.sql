BEGIN;

CREATE OR REPLACE FUNCTION accounting.get_live_open_bets ()
RETURNS TABLE (
    id BIGINT, client_loginid VARCHAR, currency_code VARCHAR, short_code VARCHAR, buy_price NUMERIC, transaction_id BIGINT
) AS $SQL$

    SELECT
        id,
        client_loginid,
        currency_code,
        short_code,
        buy_price,
        transaction_id
    FROM
        betonmarkets.production_servers() srv,
        LATERAL dblink(srv.srvname,
        $$
            SELECT
                fmb.id,
                acc.client_loginid,
                acc.currency_code,
                fmb.short_code,
                fmb.buy_price,
                txn.id AS transaction_id
            FROM
                bet.financial_market_bet AS fmb,
                transaction.account AS acc,
                transaction.transaction AS txn
            WHERE
                fmb.account_id = acc.id
                AND fmb.id = txn.financial_market_bet_id
                AND fmb.is_sold IS false
                AND fmb.bet_class <> 'run_bet'
                AND fmb.bet_class <> 'legacy_bet'
        $$
        ) AS t(id BIGINT, client_loginid VARCHAR, currency_code VARCHAR, short_code VARCHAR, buy_price NUMERIC, transaction_id BIGINT)

$SQL$
LANGUAGE sql STABLE;

COMMIT;
