BEGIN;

-- this implements the FREE_BET promo code limit.

SELECT r.*
  FROM (
    VALUES ('BI010', 'maximum balance reached for betting without a real deposit')
  ) dat(code, explanation)
CROSS JOIN LATERAL betonmarkets.update_custom_pg_error_code(dat.code, dat.explanation) r;

CREATE OR REPLACE FUNCTION bet.validate_max_balance_without_real_deposit(p_account transaction.account,
                                                                         p_rate    NUMERIC,
                                                                         p_limits  JSON)
RETURNS VOID AS $def$
BEGIN
    -- limits are given in USD
    IF (p_limits -> 'max_balance_without_real_deposit') IS NOT NULL AND
       p_account.balance * p_rate > (p_limits ->> 'max_balance_without_real_deposit')::NUMERIC THEN
        PERFORM 1
           FROM payment.payment p
           JOIN transaction.account a ON (a.id=p.account_id)
          WHERE p.payment_gateway_code<>'free_gift'
            AND a.client_loginid=p_account.client_loginid
          LIMIT 1;

        IF NOT FOUND THEN
            RAISE EXCEPTION USING
                MESSAGE=(SELECT explanation FROM betonmarkets.custom_pg_error_codes WHERE code='BI010'),
                ERRCODE='BI010';
        END IF;
    END IF;
END
$def$ LANGUAGE plpgsql VOLATILE;

COMMIT;
