BEGIN;
SET search_path = public, pg_catalog;

CREATE OR REPLACE FUNCTION get_historical_open_bets_overview(start_date timestamp without time zone) RETURNS TABLE(account_id bigint, loginid character varying, currency_code character varying, id bigint, buy_price numeric, expiry_time timestamp without time zone, payout_price numeric, short_code character varying, name character varying, myaffiliates_token character varying, market_price numeric, percentage_change numeric, ref bigint, calculation_time timestamp without time zone)
    LANGUAGE sql STABLE
    AS $_$

    WITH realtime_book_bet AS (
        SELECT * FROM dblink('dc',
        $$
            WITH calc_time AS (
                SELECT
                    max(calculation_time) as time_before
                FROM
                    accounting.realtime_book_archive
                WHERE
                    calculation_time <= $$ || quote_literal($1) || $$
            )
            SELECT
                financial_market_bet_id,
                market_price,
                calculation_time
            FROM
                accounting.realtime_book_archive
            WHERE
                calculation_time = (SELECT time_before FROM calc_time)
        $$
        ) AS t(financial_market_bet_id BIGINT, market_price NUMERIC, calculation_time TIMESTAMP)
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
        t.id AS ref,
        r.calculation_time
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
        AND t.action_type = 'buy'

$_$;

COMMIT;
