BEGIN;

SELECT r.*
  FROM (
    VALUES ('BI013', 'maximum self-exclusion 7 day turnover limit exceeded'),
           ('BI014', 'maximum self-exclusion 7 day limit on losses exceeded')
  ) dat(code, explanation)
CROSS JOIN LATERAL betonmarkets.update_custom_pg_error_code(dat.code, dat.explanation) r;

CREATE OR REPLACE FUNCTION bet.validate_7day_limits(p_account           transaction.account,
                                                    p_purchase_time     TIMESTAMP,
                                                    p_buy_price         NUMERIC,
                                                    p_limits            JSON)
RETURNS VOID AS $def$
DECLARE
    v_r                RECORD;
    v_potential_losses NUMERIC;
BEGIN
    IF (p_limits -> 'max_7day_losses') IS NOT NULL THEN
        v_potential_losses:=bet.calculate_potential_losses(p_account);
    END IF;

    IF (p_limits -> 'max_7day_turnover') IS NOT NULL OR
       (p_limits -> 'max_7day_losses') IS NOT NULL THEN
        SELECT INTO v_r
               coalesce(sum(b.buy_price), 0) AS turnover,
               coalesce(sum(b.buy_price - b.sell_price), 0) AS loss
          FROM bet.financial_market_bet b
         WHERE b.account_id=p_account.id
           AND date_trunc('day', p_purchase_time) - '6d'::INTERVAL <= b.purchase_time
           AND b.purchase_time < date_trunc('day', p_purchase_time) + '1d'::INTERVAL;

        IF v_r.turnover + p_buy_price > (p_limits ->> 'max_7day_turnover')::NUMERIC THEN
            RAISE EXCEPTION USING
                MESSAGE=(SELECT explanation FROM betonmarkets.custom_pg_error_codes WHERE code='BI013'),
                ERRCODE='BI013';
        END IF;

        IF v_r.loss + v_potential_losses + p_buy_price > (p_limits ->> 'max_7day_losses')::NUMERIC THEN
            RAISE EXCEPTION USING
                MESSAGE=(SELECT explanation FROM betonmarkets.custom_pg_error_codes WHERE code='BI014'),
                ERRCODE='BI014';
        END IF;
    END IF;
END
$def$ LANGUAGE plpgsql VOLATILE;

COMMIT;
