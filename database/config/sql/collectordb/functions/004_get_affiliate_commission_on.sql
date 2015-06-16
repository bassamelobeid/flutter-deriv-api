BEGIN;

CREATE OR REPLACE FUNCTION data_collection.get_affiliate_commission_on (server TEXT, start_date TIMESTAMP, end_date TIMESTAMP)
RETURNS TABLE (
    myaffiliates_token TEXT, effective_date DATE, intraday_turnover NUMERIC, runbet_turnover NUMERIC, other_turnover NUMERIC, pnl NUMERIC
) AS $SQL$

    SELECT * FROM dblink($1,
    $$
        SELECT
            c.myaffiliates_token,
            date_trunc('month', t.transaction_time) as effective_date,

            sum(CASE
                    WHEN t.action_type = 'buy' AND (b.expiry_time - b.start_time) < interval '1 day' AND tick_count IS NULL
                        THEN round(-exch.rate * t.amount, 4)
                    ELSE 0::NUMERIC(14,4)
                END) as intraday_turnover,

            sum(CASE
                    WHEN t.action_type = 'buy' AND tick_count IS NOT NULL
                        THEN round(-exch.rate * t.amount, 4)
                    ELSE 0::NUMERIC(14,4)
                END) as runbet_turnover,

            sum(CASE
                    WHEN t.action_type = 'buy' AND (b.expiry_time - b.start_time) >= interval '1 day' AND tick_count IS NULL
                        THEN round(-exch.rate * t.amount, 4)
                    ELSE 0::NUMERIC(14,4)
                END) as other_turnover,

            sum(CASE
                    WHEN t.action_type = 'sell'
                        THEN round(exch.rate * (b.buy_price - b.sell_price), 4)
                    ELSE 0::NUMERIC(14,4)
                END) as pnl
        FROM
            betonmarkets.client c,
            transaction.account a,
            transaction.transaction t,
            bet.financial_market_bet b
            LEFT JOIN data_collection.exchangetousd_rate(a.currency_code, t.transaction_time) exch(rate) ON true
        WHERE
            c.loginid = a.client_loginid
            AND t.account_id = a.id
            AND b.id = t.financial_market_bet_id
            AND c.myaffiliates_token IS NOT NULL
            AND c.myaffiliates_token <> ''
            AND date_trunc('day', t.transaction_time) >= $$ || quote_literal($2) || $$
            AND date_trunc('day', t.transaction_time) <= $$ || quote_literal($3) || $$
        GROUP BY
            myaffiliates_token,
            date_trunc('month', t.transaction_time)
    $$
    ) AS t(myaffiliates_token TEXT, effective_date DATE, intraday_turnover NUMERIC, runbet_turnover NUMERIC, other_turnover NUMERIC, pnl NUMERIC)

$SQL$
LANGUAGE sql STABLE SECURITY definer;

COMMIT;
