BEGIN;

CREATE OR REPLACE FUNCTION get_open_bets_overview ()
RETURNS TABLE (
    account_id BIGINT, loginid VARCHAR, currency_code VARCHAR, id BIGINT, buy_price NUMERIC, expiry_time TIMESTAMP, payout_price NUMERIC,
    short_code VARCHAR, name VARCHAR, myaffiliates_token VARCHAR, market_price NUMERIC, percentage_change NUMERIC, ref BIGINT
) AS $SQL$

    WITH realtime_book_bet AS (
        SELECT * FROM dblink('dc',
        $$
            SELECT
                financial_market_bet_id,
                market_price
            FROM
                accounting.realtime_book
        $$
        ) AS t(financial_market_bet_id BIGINT, market_price NUMERIC)
    )
    SELECT
        a.id AS account_id,
        a.client_loginid AS loginid,
        a.currency_code,
        b.id,
        b.buy_price,
        b.expiry_time,
        b.payout_price,
        b.short_code,
        concat(c.first_name, ' ', c.last_name) as name,
        c.myaffiliates_token,
        ROUND( (r.market_price / data_collection.exchangetousd(1, a.currency_code))::NUMERIC, 4 ) as market_price,
        ROUND( (100 * ((r.market_price / data_collection.exchangetousd(1, a.currency_code)) / b.buy_price -1))::NUMERIC, 1 ) as percentage_change,
        t.id AS ref
    FROM
        betonmarkets.client c,
        transaction.account a,
        transaction.transaction t,
        bet.financial_market_bet b,
        realtime_book_bet r
    WHERE
        a.client_loginid = c.loginid
        AND b.account_id = a.id
        AND t.financial_market_bet_id = b.id
        AND r.financial_market_bet_id = b.id
        AND b.buy_price > 0

$SQL$
LANGUAGE sql STABLE;

COMMIT;
