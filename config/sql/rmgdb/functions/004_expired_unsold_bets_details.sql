BEGIN;
SET search_path = public, pg_catalog;

CREATE OR REPLACE FUNCTION expired_unsold_bets_details() RETURNS TABLE(id bigint, financial_market_bet_id bigint, market_price numeric, client_loginid character varying, currency_code character varying, buy_price numeric, ref_number bigint)
    LANGUAGE sql STABLE
    AS $_$

    WITH expired_unsold AS (
        SELECT * FROM dblink('dc',
        $$
            SELECT * FROM accounting.expired_unsold
        $$
        ) AS t(id BIGINT, financial_market_bet_id BIGINT, market_price NUMERIC)
    )

    SELECT
        e.id,
        e.financial_market_bet_id,
        e.market_price,
        a.client_loginid,
        a.currency_code,
        b.buy_price,
        t.id as ref_number
    FROM
        expired_unsold e,
        transaction.account a,
        transaction.transaction t,
        bet.financial_market_bet b
    WHERE
        a.id = b.account_id
        AND t.financial_market_bet_id = b.id
        AND e.financial_market_bet_id = b.id
        AND NOT (b.is_sold)

$_$;

COMMIT;
