BEGIN;
SET search_path = public, pg_catalog;

CREATE OR REPLACE FUNCTION get_active_accounts_payment_profit(start_time timestamp without time zone, end_time timestamp without time zone) RETURNS TABLE(account_id bigint, loginid character varying, currency character varying, name character varying, myaffiliates_token character varying, usd_payments numeric, usd_profit numeric, payments numeric, profit numeric)
    LANGUAGE sql STABLE
    AS $_$

    WITH open_bets_start_profit as (
        SELECT
            account_id,
            loginid as client_loginid,
            currency_code,
            name,
            myaffiliates_token,
            SUM(market_price) - SUM(buy_price) as profit
        FROM
            (
                SELECT * FROM get_historical_open_bets_overview($1)
            ) t
        GROUP BY 1,2,3,4,5
    ),
    open_bets_end_profit as (
        SELECT
            account_id,
            loginid as client_loginid,
            currency_code,
            name,
            myaffiliates_token,
            SUM(market_price) - SUM(buy_price) as profit
        FROM
            (
                SELECT * FROM get_historical_open_bets_overview($2)
            ) t
        GROUP BY 1,2,3,4,5
    ),
    active_accounts as (
        SELECT
            a.id as account_id,
            a.client_loginid,
            a.currency_code,
            concat(c.first_name, ' ', c.last_name) as name,
            c.myaffiliates_token
        FROM
            transaction.account a,
            betonmarkets.client c
        WHERE
            c.loginid = a.client_loginid
            AND a.id IN (
                SELECT
                    distinct(account_id) as account_id
                FROM
                    transaction.transaction
                WHERE
                    transaction_time >= $1
                    AND transaction_time < $2
            )
    ),
    profit_since_start as (
        SELECT
            a.account_id,
            SUM(
                CASE WHEN b.bet_class = 'run_bet'
                THEN amount
                ELSE sell_price - buy_price
                END
            ) AS profit
        FROM
            transaction.transaction t,
            bet.financial_market_bet b,
            active_accounts a
        WHERE
            a.account_id = t.account_id
            AND t.financial_market_bet_id = b.id
            AND ( (b.bet_class <> 'run_bet' AND action_type = 'sell') OR b.bet_class = 'run_bet' )
            AND t.transaction_time >= $1
        GROUP BY 1
    ),
    profit_since_end as (
        SELECT
            a.account_id,
            SUM(
                CASE WHEN b.bet_class = 'run_bet'
                THEN amount
                ELSE sell_price - buy_price
                END
            ) AS profit
        FROM
            transaction.transaction t,
            bet.financial_market_bet b,
            active_accounts a
        WHERE
            a.account_id = t.account_id
            AND t.financial_market_bet_id = b.id
            AND ( (b.bet_class <> 'run_bet' AND action_type = 'sell') OR b.bet_class = 'run_bet' )
            AND t.transaction_time >= $2
        GROUP BY 1
    ),
    total_payment as (
        SELECT
            a.account_id,
            SUM(p.amount) as amount
        FROM
            active_accounts a,
            payment.payment p
        WHERE
            a.account_id = p.account_id
            AND p.payment_time >= $1
            AND p.payment_time < $2
        GROUP BY 1
    ),
    active_accounts_include_open_bets as (
        SELECT * FROM active_accounts
        UNION
            SELECT
                account_id,
                client_loginid,
                currency_code,
                name,
                myaffiliates_token
            FROM
                open_bets_start_profit
        UNION
            SELECT
                account_id,
                client_loginid,
                currency_code,
                name,
                myaffiliates_token
            FROM
                open_bets_end_profit
    )

    SELECT
        a.account_id,
        a.client_loginid as loginid,
        a.currency_code as currency,
        a.name,
        a.myaffiliates_token,
        ROUND( data_collection.exchangetousd( COALESCE(p.amount, 0), a.currency_code ), 2 ) as USD_payments,
        ROUND( data_collection.exchangetousd( (COALESCE(ps.profit, 0) - COALESCE(pe.profit, 0) + COALESCE(oe.profit, 0) - COALESCE(os.profit, 0)), a.currency_code ), 2 ) as USD_profit,
        ROUND( COALESCE(p.amount, 0), 2 ) as payments,
        ROUND( ( COALESCE(ps.profit, 0) - COALESCE(pe.profit, 0) + COALESCE(oe.profit, 0) - COALESCE(os.profit, 0) ), 2 ) as profit
    FROM
        active_accounts_include_open_bets a

        LEFT JOIN open_bets_start_profit os
            ON a.account_id = os.account_id

        LEFT JOIN open_bets_end_profit oe
            ON a.account_id = oe.account_id

        LEFT JOIN total_payment p
            ON a.account_id = p.account_id

        LEFT JOIN profit_since_start ps
            ON a.account_id = ps.account_id

        LEFT JOIN profit_since_end pe
            ON a.account_id = pe.account_id

$_$;

COMMIT;
