BEGIN;
SET search_path = public, pg_catalog;

CREATE OR REPLACE FUNCTION turnover_in_period(start_time timestamp without time zone, end_time timestamp without time zone) RETURNS TABLE(accid bigint, loginid character varying, currency character varying, name character varying, myaffiliates_token character varying, turnover numeric)
    LANGUAGE sql STABLE
    AS $_$

    SELECT
        a.id AS accid,
        a.client_loginid AS loginid,
        currency_code AS currency,
        concat(c.first_name, ' ', c.last_name) as name,
        c.myaffiliates_token,
        round(-1 * SUM( data_collection.exchangetousd(amount, currency_code) ), 2) as turnover
    FROM
        betonmarkets.client c,
        transaction.account a,
        transaction.transaction t
    WHERE
        c.loginid = a.client_loginid
        AND t.account_id = a.id
        AND t.action_type = 'buy'
        AND t.transaction_time > $1
        AND t.transaction_time < $2
    GROUP BY 1,2,3,4,5

$_$;

COMMIT;
