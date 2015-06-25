BEGIN;
SET search_path = public, pg_catalog;

CREATE OR REPLACE FUNCTION daily_turnover_for_date_range_on(broker character varying, start_date timestamp without time zone, end_date timestamp without time zone) RETURNS TABLE(txn_date date, buy_usd numeric, sell_usd numeric, buy_gbp numeric, sell_gbp numeric, buy_aud numeric, sell_aud numeric, buy_eur numeric, sell_eur numeric, total_buy_usd numeric, total_sell_usd numeric, buy_minus_sell_usd numeric, open_bet_pl_usd numeric, open_bet_pl_gbp numeric, open_bet_pl_aud numeric, open_bet_pl_eur numeric, total_open_bet_pl_usd numeric, outstanding_bet_usd numeric, outstanding_bet_gbp numeric, outstanding_bet_aud numeric, outstanding_bet_eur numeric, total_outstanding_bet_usd numeric, agg_cash_bal_usd numeric, pl_on_day numeric)
    LANGUAGE sql STABLE
    AS $_$

WITH out_bet as (
    SELECT * FROM dblink('dc',
    $$
        SELECT
            bal.effective_date::date as out_date,
            bal.account_id,
            bal.balance,
            sum(open.marked_to_market_value) as out_bet_value
        FROM
            accounting.end_of_day_balances bal
            LEFT JOIN accounting.end_of_day_open_positions open
                ON open.end_of_day_balance_id = bal.id
        WHERE
            bal.effective_date::date >= (date $$ || quote_literal($2) || $$ - interval '1 day')
            AND bal.effective_date::date <= $$ || quote_literal($3) || $$
        GROUP BY 1,2,3
    $$
    ) AS t(out_date DATE, account_id BIGINT, balance NUMERIC, out_bet_value NUMERIC)
),
outstanding_bet as (
    SELECT
        out_date,
        total_balance,
        out_bet_usd,
        out_bet_gbp,
        out_bet_aud,
        out_bet_eur,
        total_out_bet_usd,
        lag(out_bet_usd) OVER (ORDER BY out_date) - out_bet_usd as open_bet_PL_usd,
        lag(out_bet_gbp) OVER (ORDER BY out_date) - out_bet_gbp as open_bet_PL_gbp,
        lag(out_bet_aud) OVER (ORDER BY out_date) - out_bet_aud as open_bet_PL_aud,
        lag(out_bet_eur) OVER (ORDER BY out_date) - out_bet_eur as open_bet_PL_eur,
        lag(total_out_bet_usd) OVER (ORDER BY out_date) - total_out_bet_usd as total_open_bet_PL_usd
    FROM (
        SELECT
            out_date,
            SUM( data_collection.exchangetousd(b.balance, a.currency_code) ) as total_balance,
            SUM( CASE WHEN a.currency_code = 'USD' THEN b.out_bet_value ELSE 0 END ) as out_bet_usd,
            SUM( CASE WHEN a.currency_code = 'GBP' THEN b.out_bet_value ELSE 0 END ) as out_bet_gbp,
            SUM( CASE WHEN a.currency_code = 'AUD' THEN b.out_bet_value ELSE 0 END ) as out_bet_aud,
            SUM( CASE WHEN a.currency_code = 'EUR' THEN b.out_bet_value ELSE 0 END ) as out_bet_eur,
            SUM( data_collection.exchangetousd(b.out_bet_value, a.currency_code) ) AS total_out_bet_usd
        FROM
            out_bet b,
            transaction.account a,
            betonmarkets.client c
        WHERE
            c.loginid = a.client_loginid
            AND a.id = b.account_id
            AND c.broker_code = $1
        GROUP BY
            out_date
        ORDER BY
            out_date
    ) t
),
buy_sell as (
    SELECT
        t.transaction_time::date as txn_date,
        -1 * ROUND(SUM( CASE WHEN t.action_type = 'buy' AND a.currency_code = 'USD' THEN t.amount ELSE 0 END)::numeric, 2) AS buy_USD,
        ROUND(SUM( CASE WHEN t.action_type = 'sell' AND a.currency_code = 'USD' THEN t.amount ELSE 0 END )::numeric, 2) AS sell_USD,
        -1 * ROUND(SUM( CASE WHEN t.action_type = 'buy' AND a.currency_code = 'GBP' THEN t.amount ELSE 0 END )::numeric, 2) AS buy_GBP,
        ROUND(SUM( CASE WHEN t.action_type = 'sell' and a.currency_code = 'GBP' THEN t.amount ELSE 0 END )::numeric, 2) AS sell_GBP,
        -1 * ROUND(SUM( CASE WHEN t.action_type = 'buy' and a.currency_code = 'AUD' THEN t.amount ELSE 0 END )::numeric, 2) AS buy_AUD,
        ROUND(SUM( CASE WHEN t.action_type = 'sell' AND a.currency_code = 'AUD' THEN t.amount ELSE 0 END )::numeric, 2) AS sell_AUD,
        -1 * ROUND(SUM( CASE WHEN t.action_type = 'buy' and a.currency_code = 'EUR' THEN t.amount ELSE 0 END )::numeric, 2) AS buy_EUR,
        ROUND(SUM( CASE WHEN t.action_type = 'sell' and a.currency_code = 'EUR' THEN t.amount ELSE 0 END )::numeric, 2) AS sell_EUR,
        -1 * ROUND(SUM( CASE WHEN t.action_type = 'buy' THEN data_collection.exchangetousd(t.amount, a.currency_code) ELSE 0 END )::numeric, 2) AS total_buy_USD,
        ROUND(SUM( CASE WHEN t.action_type = 'sell' THEN data_collection.exchangetousd(t.amount, a.currency_code) ELSE 0 END )::numeric, 2) AS total_sell_USD,
        -1 * ROUND(SUM( CASE WHEN (t.action_type = 'sell' OR t.action_type = 'buy') THEN data_collection.exchangetousd(t.amount, a.currency_code) ELSE 0 END )::numeric, 2) AS buy_minus_sell_USD

    FROM
        transaction.transaction t,
        transaction.account a,
        betonmarkets.client c
    WHERE
        t.transaction_time::date >= $2
        and t.transaction_time::date <= $3
        and t.account_id = a.id
        and c.loginid = a.client_loginid
        and c.broker_code = $1
    GROUP BY
        t.transaction_time::date
    ORDER BY
        txn_date
)

SELECT
    o.out_date as txn_date,
    b.buy_USD,
    b.sell_USD,
    b.buy_GBP,
    b.sell_GBP,
    b.buy_AUD,
    b.sell_AUD,
    b.buy_EUR,
    b.sell_EUR,
    b.total_buy_USD,
    b.total_sell_USD,
    b.buy_minus_sell_USD,
    ROUND(o.open_bet_PL_usd::numeric, 2) as open_bet_PL_USD,
    ROUND(o.open_bet_PL_gbp::numeric, 2) as open_bet_PL_GBP,
    ROUND(o.open_bet_PL_aud::numeric, 2) as open_bet_PL_AUD,
    ROUND(o.open_bet_PL_eur::numeric, 2) as open_bet_PL_EUR,
    ROUND(o.total_open_bet_PL_usd::numeric, 2) as total_open_bet_PL_USD,
    ROUND(o.out_bet_usd::numeric, 2) AS outstanding_bet_USD,
    ROUND(o.out_bet_gbp::numeric, 2) AS outstanding_bet_GBP,
    ROUND(o.out_bet_aud::numeric, 2) AS outstanding_bet_AUD,
    ROUND(o.out_bet_eur::numeric, 2) AS outstanding_bet_EUR,
    ROUND(o.total_out_bet_usd::numeric, 2) AS total_outstanding_bet_USD,
    ROUND(o.total_balance::numeric, 2) AS Agg_Cash_Bal_USD,
    ROUND( (b.buy_minus_sell_USD + o.total_open_bet_PL_usd)::numeric, 2 ) AS PL_on_day
FROM
    outstanding_bet o
    LEFT JOIN buy_sell b
        ON b.txn_date = o.out_date
WHERE
    o.out_date >= $2
    AND o.out_date <= $3
ORDER BY o.out_date

$_$;

COMMIT;
