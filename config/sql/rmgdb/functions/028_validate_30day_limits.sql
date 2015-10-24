BEGIN;

SELECT r.*
  FROM (
    VALUES ('BI016', 'maximum self-exclusion 30 day turnover limit exceeded'),
           ('BI017', 'maximum self-exclusion 30 day limit on losses exceeded')
  ) dat(code, explanation)
CROSS JOIN LATERAL betonmarkets.update_custom_pg_error_code(dat.code, dat.explanation) r;

CREATE OR REPLACE FUNCTION bet.validate_30day_limits(p_account           transaction.account,
                                                     p_rate              NUMERIC,
                                                     p_purchase_time     TIMESTAMP,
                                                     p_buy_price         NUMERIC,
                                                     p_limits            JSON)
RETURNS VOID AS $def$
DECLARE
    v_r                RECORD;
    v_potential_losses NUMERIC;
BEGIN
    IF (p_limits -> 'max_30day_losses') IS NOT NULL THEN
        v_potential_losses:=bet.calculate_potential_losses(p_account.client_loginid);
    END IF;

    IF (p_limits -> 'max_30day_turnover') IS NOT NULL OR
       (p_limits -> 'max_30day_losses') IS NOT NULL THEN
        SELECT INTO v_r
               coalesce(sum(b.buy_price * e.rate), 0) AS turnover,
               coalesce(sum((b.buy_price - b.sell_price) * e.rate), 0) AS loss
          FROM bet.financial_market_bet b
          JOIN transaction.account a ON a.id = b.account_id
         CROSS JOIN data_collection.exchangeToUSD_rate(a.currency_code, p_purchase_time) e
         WHERE a.client_loginid=p_account.client_loginid
           AND date_trunc('day', p_purchase_time) - '29d'::INTERVAL <= b.purchase_time
           AND b.purchase_time < date_trunc('day', p_purchase_time) + '1d'::INTERVAL;

        IF v_r.turnover + p_buy_price * p_rate > (p_limits ->> 'max_30day_turnover')::NUMERIC THEN
            RAISE EXCEPTION USING
                MESSAGE=(SELECT explanation FROM betonmarkets.custom_pg_error_codes WHERE code='BI016'),
                ERRCODE='BI016';
        END IF;

        IF v_r.loss + v_potential_losses + p_buy_price * p_rate > (p_limits ->> 'max_30day_losses')::NUMERIC THEN
            RAISE EXCEPTION USING
                MESSAGE=(SELECT explanation FROM betonmarkets.custom_pg_error_codes WHERE code='BI017'),
                ERRCODE='BI017';
        END IF;
    END IF;
END
$def$ LANGUAGE plpgsql VOLATILE;

COMMIT;
