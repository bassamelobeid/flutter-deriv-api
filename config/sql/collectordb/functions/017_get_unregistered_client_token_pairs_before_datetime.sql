BEGIN;

CREATE OR REPLACE FUNCTION get_unregistered_client_token_pairs_before_datetime (to_date TIMESTAMP)
RETURNS TABLE (
    loginid TEXT,
    date_joined TIMESTAMP,
    myaffiliates_token TEXT,
    is_creative BOOL,
    id BIGINT
) AS $SQL$

    SELECT rem.*
    FROM
        betonmarkets.production_servers() s,
        dblink(s.srvname, $$

            -- clients with token, no promocode
            SELECT
                c.loginid AS loginid,
                c.date_joined,
                c.myaffiliates_token AS myaffiliates_token,
                false AS is_creative,
                0 AS id
            FROM
                betonmarkets.client c
                LEFT JOIN betonmarkets.client_promo_code p
                    ON c.loginid = p.client_loginid
            WHERE
                c.myaffiliates_token IS NOT NULL
                AND c.myaffiliates_token_registered IS FALSE
                AND c.date_joined <= $$ || quote_literal($1) || $$
                AND p.promotion_code IS NULL

            -- clients with promocode
            UNION
            SELECT
                c.loginid AS loginid,
                p.apply_date,
                c.myaffiliates_token AS myaffiliates_token,
                false AS is_creative,
                0 AS id
            FROM
                betonmarkets.client c
                LEFT JOIN betonmarkets.client_promo_code p
                    ON c.loginid = p.client_loginid
            WHERE
                c.myaffiliates_token IS NOT NULL
                AND c.myaffiliates_token_registered IS FALSE
                AND p.promotion_code IS NOT NULL
                AND p.checked_in_myaffiliates IS TRUE
                AND p.apply_date <= $$ || quote_literal($1) || $$

            -- creative media exposures and signup overrides
            UNION
            SELECT
                e.client_loginid AS loginid,
                e.exposure_record_date,
                e.myaffiliates_token AS myaffiliates_token,
                true AS is_creative,
                e.id AS id
            FROM
                betonmarkets.client_affiliate_exposure e
            WHERE
                e.myaffiliates_token IS NOT NULL
                AND e.exposure_record_date <= $$ || quote_literal($1) || $$
                AND (
                    e.pay_for_exposure IS TRUE
                    OR e.signup_override IS TRUE
                )
                AND e.myaffiliates_token_registered IS FALSE;

        $$) rem(
            loginid TEXT,
            date_joined TIMESTAMP,
            myaffiliates_token TEXT,
            is_creative BOOL,
            id BIGINT
        )

$SQL$
LANGUAGE sql STABLE;

COMMIT;
