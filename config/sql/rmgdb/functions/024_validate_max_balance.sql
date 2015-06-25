BEGIN;

SELECT r.*
  FROM (
    VALUES ('BI008', 'client balance upper limit exceeded')
  ) dat(code, explanation)
CROSS JOIN LATERAL betonmarkets.update_custom_pg_error_code(dat.code, dat.explanation) r;

CREATE OR REPLACE FUNCTION bet.validate_max_balance(p_account transaction.account,
                                                    p_rate    NUMERIC,
                                                    p_limits  JSON)
RETURNS VOID AS $def$
BEGIN
    -- limits are given in USD
    IF (p_limits -> 'max_balance') IS NOT NULL AND
       p_account.balance * p_rate > (p_limits ->> 'max_balance')::NUMERIC THEN
        RAISE EXCEPTION USING
            MESSAGE=(SELECT explanation FROM betonmarkets.custom_pg_error_codes WHERE code='BI008'),
            ERRCODE='BI008';
    END IF;
END
$def$ LANGUAGE plpgsql VOLATILE;

COMMIT;
