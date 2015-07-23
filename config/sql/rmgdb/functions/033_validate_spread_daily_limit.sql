BEGIN;

SELECT r.*
  FROM (
    VALUES ('BI017', 'daily trading limit exceeded')
  ) dat(code, explanation)
CROSS JOIN LATERAL betonmarkets.update_custom_pg_error_code(dat.code, dat.explanation) r;

CREATE OR REPLACE FUNCTION test(client_id           VARCHAR,
                                currency            VARCHAR,
                                p_limits            NUMERIC)

RETURNS BOOLEAN AS $def$
DECLARE
    realized_profit  NUMERIC;
    potential_profit NUMERIC;
BEGIN
    CREATE TEMP VIEW spread_bets AS
        SELECT  b.id as fmb_id,
                b.buy_price as buy_price,
                b.sell_price as sell_price,
                sb.amount_per_point as amount_per_point,
                sb.stop_profit as stop_profit,
                b.is_sold as is_sold FROM
                    (SELECT * FROM bet.financial_market_bet WHERE bet_class='spread_bet' AND purchase_time > now()::date) b
                    JOIN transaction.account a ON
                    a.id = b.account_id
                    JOIN bet.spread_bet sb ON
                    b.id = sb.financial_market_bet_id
                    WHERE a.currency_code='USD'
                        AND a.client_loginid='VRTC380000';

    SELECT INTO
        potential_profit SUM(amount_per_point * stop_profit)
        FROM spread_bets
            WHERE is_sold IS FALSE;

    SELECT INTO
        realized_profit SUM(sell_price - buy_price)
        FROM spread_bets
            WHERE is_sold IS TRUE;

    IF realized_profit IS NOT NULL OR potential_profit IS NOT NULL THEN
        IF potential_profit + realized_profit > p_limits THEN
            RAISE EXCEPTION USING
                MESSAGE=(SELECT explanation FROM betonmarkets.custom_pg_error_codes WHERE code='BI017'),
                ERRCODE='BI017';
        END IF;
    END IF;

    RETURN TRUE;
END
$def$ LANGUAGE plpgsql VOLATILE;

COMMIT;
