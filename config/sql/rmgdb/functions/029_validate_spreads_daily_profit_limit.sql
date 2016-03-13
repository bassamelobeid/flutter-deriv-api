BEGIN;

SELECT r.*
  FROM (
    VALUES ('BI015', 'daily profit limit on spread bets exceeded')
  ) dat(code, explanation)
CROSS JOIN LATERAL betonmarkets.update_custom_pg_error_code(dat.code, dat.explanation) r;

CREATE OR REPLACE FUNCTION bet_v1.validate_spreads_daily_profit_limit(  p_account           transaction.account,
                                                                        p_purchase_time     TIMESTAMP,
                                                                        p_chld              JSON,
                                                                        p_limits            JSON)
RETURNS BOOLEAN AS $def$
DECLARE
    v_profit  NUMERIC;
BEGIN
    IF (p_limits -> 'spread_bet_profit_limit') IS NOT NULL THEN
        SELECT INTO v_profit
               sum(CASE WHEN b.is_sold
                        THEN b.sell_price - b.buy_price
                        ELSE sb.amount_per_point * sb.stop_profit
                   END)           AS profit
          FROM bet.financial_market_bet b
          JOIN bet.spread_bet sb ON (b.id=sb.financial_market_bet_id)
         WHERE b.account_id=p_account.id
           AND b.purchase_time::DATE=p_purchase_time::DATE
           AND b.bet_class='spread_bet';

        IF v_profit +
           (p_chld ->> 'amount_per_point')::NUMERIC *
           (p_chld ->> 'stop_profit')::NUMERIC
            > (p_limits ->> 'spread_bet_profit_limit')::NUMERIC THEN
            RAISE EXCEPTION USING
                MESSAGE=(SELECT explanation FROM betonmarkets.custom_pg_error_codes WHERE code='BI015'),
                ERRCODE='BI015';
        END IF;
    END IF;

    RETURN TRUE;
END
$def$ LANGUAGE plpgsql VOLATILE;

COMMIT;
