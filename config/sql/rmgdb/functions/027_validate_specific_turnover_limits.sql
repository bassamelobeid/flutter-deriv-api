BEGIN;

-- NOTE: for performance reasons, this function also validates max_turnover and max_losses

SELECT r.*
  FROM (
    VALUES ('BI001', 'maximum self-exclusion turnover limit exceeded'),
           ('BI011', 'specific turnover limit reached: %s'),
           ('BI012', 'maximum self-exclusion limit on daily losses reached')
  ) dat(code, explanation)
CROSS JOIN LATERAL betonmarkets.update_custom_pg_error_code(dat.code, dat.explanation) r;


CREATE OR REPLACE FUNCTION bet_v1.validate_specific_turnover_limits(p_account           transaction.account,
                                                                    p_purchase_time     TIMESTAMP,
                                                                    p_buy_price         NUMERIC,
                                                                    p_limits            JSON)
RETURNS VOID AS $def$
DECLARE
    v_arr              TEXT[];
    v_sql              TEXT;
    v_r                RECORD;
    v_potential_losses NUMERIC;
BEGIN
    IF (p_limits -> 'max_losses') IS NOT NULL THEN
        v_potential_losses:=bet_v1.calculate_potential_losses(p_account);
    END IF;

    IF (p_limits -> 'specific_turnover_limits') IS NOT NULL OR
       (p_limits -> 'max_turnover') IS NOT NULL OR
       (p_limits -> 'max_losses') IS NOT NULL THEN
        -- The "SELECT INTO v_sql" below takes the JSON array (represented in Perl syntax):
        --
        -- [
        --      {
        --          bet_type => [map {{n => $_}} qw/FLASHU FLASHD .../],
        --          symbols  => [map {{n => $_}} qw/frxUSDJPY frxUSDGBP .../],
        --          limit    => 10000,
        --          name     => 'NAME1',
        --      },
        --      {
        --          bet_type => [map {{n => $_}} qw/FLASHU FLASHD .../],
        --          limit    => 20000,
        --          name     => 'NAME2',
        --      },
        --      {
        --          symbols     => [map {{n => $_}} qw/frxUSDJPY frxUSDGBP .../],
        --          tick_expiry => 1,
        --          limit       => 30000,
        --          name        => 'NAME3',
        --      },
        --  ]
        --
        -- and transforms it into this SELECT:
        --
        -- SELECT array_remove(ARRAY[
        --                         CASE WHEN b_buy_price +
        --                                   coalesce(sum(CASE WHEN (b.underlying_symbol='frxUSDJPY' OR
        --                                                           b.underlying_symbol='frxUSDGBP' OR
        --                                                           b.underlying_symbol='...')
        --                                                      AND (b.bet_type='FLASHU' OR
        --                                                           b.bet_type='FLASHD' OR
        --                                                           b.bet_type='...')
        --                                                      THEN b.buy_price END), 0) > 10000
        --                              THEN 'NAME1' END,
        --                         CASE WHEN b_buy_price +
        --                                   coalesce(sum(CASE WHEN (b.bet_type='FLASHU' OR
        --                                                           b.bet_type='FLASHD' OR
        --                                                           b.bet_type='...')
        --                                                      THEN b.buy_price END), 0) > 20000
        --                              THEN 'NAME2' END,
        --                         CASE WHEN b_buy_price +
        --                                   coalesce(sum(CASE WHEN (b.underlying_symbol='frxUSDJPY' OR
        --                                                           b.underlying_symbol='frxUSDGBP' OR
        --                                                           b.underlying_symbol='...')
        --                                                      AND b.tick_count IS NOT NULL
        --                                                     THEN b.buy_price END), 0) > 30000
        --                              THEN 'NAME3' END
        --                     ]::TEXT[],
        --                     NULL) AS failures
        --   FROM bet.financial_market_bet b
        --  WHERE b.account_id=$1
        --    AND b.purchase_time::DATE=$2::DATE
        --
        -- This query basically aggregates the turnover of all bets bought on the day of purchase_time
        -- for account. For each limit specified in the JSON structure, a CASE statement is
        -- generated in the select list which sums up the turnover that matches the specified condition.
        -- Then that sum is compared with its limit. If the limit is exceeded the outer CASE evalutes
        -- to the name of the limit specified in JSON. Otherwise, the outer CASE evaluates to NULL.
        -- All those names and NULLs are then collected in a string array from which the NULLs are
        -- removed. If the resulting array is empty all validations have passed. Otherwise, the array
        -- contains the list of failed validations.
        -- For the code at the Perl side that needs to evaluate which validation has failed, their
        -- names are appended to the error message. That's not ideal. I tried to use the DETAIL
        -- field of the PG exception structure but couldn't figure out how to access that with
        -- DBD::Pg.

        SELECT INTO v_arr
               coalesce(array_agg(format('CASE WHEN $3+coalesce(sum(CASE WHEN %s THEN b.buy_price END), 0) > %L THEN %L END',
                                         array_to_string(ARRAY[
                                             '(' || s.s || ')',
                                             '(' || p.t || ')',
                                             CASE WHEN (t.el -> 'tick_expiry') IS NOT NULL THEN 'b.tick_count IS NOT NULL' END
                                         ], ' AND '),
                                         t.el ->> 'limit',
                                         t.el ->> 'name')), ARRAY[]::TEXT[])
          FROM json_array_elements(p_limits -> 'specific_turnover_limits') t(el)
         CROSS JOIN LATERAL (
                    SELECT string_agg('b.underlying_symbol=' || quote_literal(syms.sym ->> 'n'), ' OR ')
                      FROM json_array_elements(t.el -> 'symbols') syms(sym)
               ) s(s)
         CROSS JOIN LATERAL (
                    SELECT string_agg('b.bet_type=' || quote_literal(types.t ->> 'n'), ' OR ')
                      FROM json_array_elements(t.el -> 'bet_type') types(t)
               ) p(t);

        IF (p_limits -> 'max_losses') IS NOT NULL THEN
            v_arr := array_prepend($$CASE WHEN $3+$4+coalesce(sum(b.buy_price - b.sell_price), 0) > $$ || quote_literal(p_limits ->> 'max_losses') || $$ THEN '_-l' END$$, v_arr);
        END IF;

        IF (p_limits -> 'max_turnover') IS NOT NULL THEN
            v_arr := array_prepend($$CASE WHEN $3+coalesce(sum(b.buy_price), 0) > $$ || quote_literal(p_limits ->> 'max_turnover') || $$ THEN '_-t' END$$, v_arr);
        END IF;

        v_sql := $$
                   SELECT array_remove(ARRAY[$$ || array_to_string(v_arr, ', ') || $$]::TEXT[], NULL) AS failures
                     FROM bet.financial_market_bet b
                    WHERE b.account_id=$1
                      AND b.purchase_time::DATE=$2::DATE
                 $$;
        -- RAISE NOTICE 'v_sql: % using 1: %, 2: %, 3: %, 4: %', v_sql, p_account.id, p_purchase_time, p_buy_price, v_potential_losses;
        EXECUTE v_sql INTO v_arr USING p_account.id, p_purchase_time, p_buy_price, v_potential_losses;
        -- RAISE NOTICE '  ==> %, upper: %', v_arr, array_upper(v_arr, 1);

        IF array_upper(v_arr, 1)>0 THEN
            IF v_arr[1] = '_-t' THEN
                RAISE EXCEPTION USING
                    MESSAGE=(SELECT explanation FROM betonmarkets.custom_pg_error_codes WHERE code='BI001'),
                    ERRCODE='BI001';
            END IF;
            IF v_arr[1] = '_-l' THEN
                RAISE EXCEPTION USING
                    MESSAGE=(SELECT explanation FROM betonmarkets.custom_pg_error_codes WHERE code='BI012'),
                    ERRCODE='BI012';
            END IF;
            RAISE EXCEPTION USING
                MESSAGE=format((SELECT explanation FROM betonmarkets.custom_pg_error_codes WHERE code='BI011'),
                               array_to_string(v_arr, ', ')),
                ERRCODE='BI011';
        END IF;
    END IF;
END
$def$ LANGUAGE plpgsql VOLATILE;

COMMIT;
