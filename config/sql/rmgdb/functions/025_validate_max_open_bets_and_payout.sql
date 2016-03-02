
BEGIN;

SELECT r.*
  FROM (
    VALUES ('BI002', 'maximum self-exclusion number of open contracts exceeded'),
           ('BI007', 'maximum summary payout for open bets per symbol and bet_type reached'),
           ('BI009', 'maximum net payout for open positions reached')
  ) dat(code, explanation)
CROSS JOIN LATERAL betonmarkets.update_custom_pg_error_code(dat.code, dat.explanation) r;

CREATE OR REPLACE FUNCTION bet_v1.validate_max_open_bets_and_payout(p_account           transaction.account,
                                                                    p_underlying_symbol VARCHAR(50),
                                                                    p_bet_type          VARCHAR(30),
                                                                    p_payout_price      NUMERIC,
                                                                    p_limits            JSON)
RETURNS VOID AS $def$
DECLARE
    v_r RECORD;
BEGIN
    IF (p_limits -> 'max_open_bets') IS NOT NULL OR
       (p_limits -> 'max_payout_open_bets') IS NOT NULL OR
       (p_limits -> 'max_payout_per_symbol_and_bet_type') IS NOT NULL THEN
        SELECT INTO v_r
               count(*) AS cnt,
               coalesce(sum(payout_price), 0) AS payout,
               coalesce(sum(CASE WHEN underlying_symbol=p_underlying_symbol
                                  AND bet_type=p_bet_type
                                 THEN payout_price END), 0) AS same_symtype
          FROM bet.financial_market_bet
         WHERE account_id=p_account.id
           AND NOT is_sold;

        IF (p_limits -> 'max_open_bets') IS NOT NULL AND
           (v_r.cnt + 1) > (p_limits ->> 'max_open_bets')::BIGINT THEN
            RAISE EXCEPTION USING
                MESSAGE=(SELECT explanation FROM betonmarkets.custom_pg_error_codes WHERE code='BI002'),
                ERRCODE='BI002';
        END IF;

        IF (p_limits -> 'max_payout_open_bets') IS NOT NULL AND
           (v_r.payout + p_payout_price) > (p_limits ->> 'max_payout_open_bets')::NUMERIC THEN
            RAISE EXCEPTION USING
                MESSAGE=(SELECT explanation FROM betonmarkets.custom_pg_error_codes WHERE code='BI009'),
                ERRCODE='BI009';
        END IF;

        IF (p_limits -> 'max_payout_per_symbol_and_bet_type') IS NOT NULL AND
           (v_r.same_symtype + p_payout_price) > (p_limits ->> 'max_payout_per_symbol_and_bet_type')::NUMERIC THEN
            RAISE EXCEPTION USING
                MESSAGE=(SELECT explanation FROM betonmarkets.custom_pg_error_codes WHERE code='BI007'),
                ERRCODE='BI007';
        END IF;
    END IF;
END
$def$ LANGUAGE plpgsql VOLATILE;

COMMIT;
