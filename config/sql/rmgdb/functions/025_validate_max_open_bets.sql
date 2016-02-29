BEGIN;

SELECT r.*
  FROM (
    VALUES ('BI002', 'maximum self-exclusion number of open contracts exceeded')
  ) dat(code, explanation)
CROSS JOIN LATERAL betonmarkets.update_custom_pg_error_code(dat.code, dat.explanation) r;

CREATE OR REPLACE FUNCTION bet_v1.validate_max_open_bets(   p_account transaction.account,
                                                            p_limits  JSON)
RETURNS VOID AS $def$
DECLARE
    v_n BIGINT;
BEGIN
    IF (p_limits -> 'max_open_bets') IS NOT NULL THEN
        SELECT INTO v_n count(*)
          FROM bet.financial_market_bet b
         WHERE b.account_id=p_account.id
           AND NOT b.is_sold;

        IF v_n+1 > (p_limits ->> 'max_open_bets')::BIGINT THEN
            RAISE EXCEPTION USING
                MESSAGE=(SELECT explanation FROM betonmarkets.custom_pg_error_codes WHERE code='BI002'),
                ERRCODE='BI002';
        END IF;
    END IF;
END
$def$ LANGUAGE plpgsql VOLATILE;

COMMIT;
