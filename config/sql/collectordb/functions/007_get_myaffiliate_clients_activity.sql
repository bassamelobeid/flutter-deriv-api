BEGIN;

CREATE OR REPLACE FUNCTION get_myaffiliate_clients_activity (start_date TIMESTAMP)
RETURNS TABLE (
    loginid VARCHAR, pnl NUMERIC, deposits NUMERIC, withdrawals NUMERIC, turnover_runbets NUMERIC,
    turnover_intradays NUMERIC, turnover_others NUMERIC, first_funded_date TIMESTAMP
) AS $SQL$

SELECT
    myaffiliate.*
FROM
    betonmarkets.production_servers() srv,
    LATERAL dblink(srv.srvname,
    $$
        WITH active_users as (
            SELECT
                DISTINCT ON (client_loginid) loginid
            FROM
                transaction.account a,
                transaction.transaction t,
                betonmarkets.client c
            WHERE
                c.loginid = a.client_loginid
                AND t.account_id = a.id
                AND c.myaffiliates_token IS NOT NULL
                AND c.myaffiliates_token <> ''
                AND date_trunc('day', t.transaction_time) = $$ || quote_literal($1) || $$
        )

        SELECT
            active_users.loginid,
            COALESCE(pnl, 0) as pnl,
            COALESCE(deposits, 0) as deposits,
            COALESCE(-1 * withdrawals, 0) as withdrawals,
            COALESCE(-1 * turnover_runbets, 0) as turnover_runbets,
            COALESCE(-1 * turnover_intradays, 0) as turnover_intradays,
            COALESCE(-1 * turnover_others, 0) as turnover_others,
            first_funded_date as first_funded_date
        FROM
            active_users

            LEFT JOIN
            (
                SELECT
                    a.client_loginid AS loginid,
                    min(date_trunc('day', p.payment_time)) as first_funded_date
                FROM
                    transaction.account a,
                    payment.payment p
                WHERE
                    p.account_id = a.id
                    AND EXISTS (SELECT 1 FROM active_users WHERE loginid = a.client_loginid)
                    AND p.payment_type_code NOT IN (
                        'free_gift',
                        'compacted_statement',
                        'cancellation',
                        'closed_account',
                        'miscellaneous',
                        'affiliate_reward',
                        'payment_fee',
                        'virtual_credit',
                        'account_transfer',
                        'currency_conversion_transfer'
                    )
                    AND p.amount > 0
                GROUP BY
                    loginid
            ) first_deposit_date ON (active_users.loginid = first_deposit_date.loginid)

            LEFT JOIN
            (
                SELECT
                    a.client_loginid AS loginid,
                    date_trunc('day', p.payment_time) as effective_date,
                    sum(CASE WHEN amount > 0 THEN round(exch.rate * amount, 4) ELSE 0 END) as deposits,
                    sum(CASE WHEN amount < 0 THEN round(exch.rate * amount, 4) ELSE 0 END) as withdrawals
                FROM
                    transaction.account a,
                    payment.payment p,
                    data_collection.exchangetousd_rate(currency_code, payment_time) exch(rate)
                WHERE
                    p.account_id = a.id
                    AND EXISTS (SELECT 1 FROM active_users WHERE loginid = a.client_loginid)
                    AND p.payment_type_code NOT IN (
                        'free_gift',
                        'compacted_statement',
                        'cancellation',
                        'closed_account',
                        'miscellaneous',
                        'affiliate_reward',
                        'payment_fee',
                        'virtual_credit',
                        'account_transfer',
                        'currency_conversion_transfer'
                    )
                    AND date_trunc('day', p.payment_time) = $$ || quote_literal($1) || $$
                GROUP BY
                    loginid,
                    date_trunc('day', p.payment_time)
            ) deposit_withdrawal ON (active_users.loginid = deposit_withdrawal.loginid)

            LEFT JOIN
            (
                SELECT
                    a.client_loginid as loginid,

                    sum(
                        CASE WHEN
                            tick_count IS NULL
                            AND ( expiry_time-start_time >= interval '1 day' or date_trunc('day',expiry_time) <> date_trunc('day',start_time) )
                        THEN round(exch.rate * amount, 4)
                        ELSE 0 END
                    ) as turnover_others,

                    sum(
                        CASE WHEN
                            tick_count IS NULL
                            AND expiry_time-start_time < interval '1 day'
                            AND date_trunc('day',expiry_time) = date_trunc('day',start_time)
                        THEN round(exch.rate * amount, 4)
                        ELSE 0 END
                    ) as turnover_intradays,

                    sum(
                        CASE WHEN
                            tick_count IS NOT NULL
                        THEN round(exch.rate * amount, 4)
                        ELSE 0 END
                    ) as turnover_runbets
                FROM
                    transaction.account a,
                    transaction.transaction t,
                    bet.financial_market_bet f,
                    data_collection.exchangetousd_rate(currency_code, transaction_time) exch(rate)

                WHERE
                    t.account_id = a.id
                    AND EXISTS (SELECT 1 FROM active_users WHERE loginid = a.client_loginid)
                    AND f.id = t.financial_market_bet_id
                    AND t.action_type = 'buy'
                    AND date_trunc('day', t.transaction_time) = $$ || quote_literal($1) || $$
                GROUP BY
                    loginid
            ) turnover ON (active_users.loginid = turnover.loginid)

            LEFT JOIN
            (
                SELECT
                    a.client_loginid AS loginid,
                    sum( round((buy_price - sell_price) * exch.rate, 4) ) as pnl
                FROM
                    transaction.account a,
                    transaction.transaction t,
                    bet.financial_market_bet b,
                    data_collection.exchangetousd_rate(currency_code, transaction_time) exch(rate)

                WHERE
                    t.account_id = a.id
                    AND EXISTS (SELECT 1 FROM active_users WHERE loginid = a.client_loginid)
                    AND b.id = t.financial_market_bet_id
                    AND action_type = 'sell'
                    AND date_trunc('day', t.transaction_time) = $$ || quote_literal($1) || $$
                GROUP BY
                    loginid,
                    date_trunc('day', t.transaction_time)
            ) pnl ON (active_users.loginid = pnl.loginid)

        ORDER BY
            active_users.loginid
    $$) AS myaffiliate(loginid VARCHAR, pnl NUMERIC, deposits NUMERIC, withdrawals NUMERIC, turnover_runbets NUMERIC, turnover_intradays NUMERIC, turnover_others NUMERIC, first_funded_date TIMESTAMP)

$SQL$
LANGUAGE sql STABLE;

COMMIT;
