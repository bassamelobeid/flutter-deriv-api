BEGIN;
SET search_path = public, pg_catalog;

CREATE OR REPLACE FUNCTION expired_unsold_bets() RETURNS TABLE(financial_market_bet_id bigint)
    LANGUAGE sql STABLE
    AS $_$

    WITH expired_unsold as (
        SELECT * FROM dblink('dc',
        $$
            SELECT financial_market_bet_id FROM accounting.expired_unsold
        $$
        ) AS t(financial_market_bet_id BIGINT)
    )

    SELECT
        u.financial_market_bet_id
    FROM
        expired_unsold u,
        bet.financial_market_bet b
    WHERE
        b.id = u.financial_market_bet_id
        AND NOT b.is_sold

$_$;

COMMIT;
