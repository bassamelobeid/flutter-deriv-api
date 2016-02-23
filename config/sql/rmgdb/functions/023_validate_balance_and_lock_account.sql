BEGIN;

SELECT r.*
  FROM (
    VALUES ('BI003', 'insufficient balance, need: %s, #open_bets: %s, pot_payout: %s')
  ) dat(code, explanation)
CROSS JOIN LATERAL betonmarkets.update_custom_pg_error_code(dat.code, dat.explanation) r;

-- Returns the account record if there is enough balance to withdraw b_buy_price.
-- Otherwise an exception is thrown.
-- Upon return, the account record is locked FOR UPDATE.
CREATE OR REPLACE FUNCTION bet_v1.validate_balance_and_lock_account( -- account
                                                                     a_loginid           VARCHAR(12),
                                                                     a_currency          VARCHAR(3),
                                                                     -- how much to withdraw
                                                                     b_buy_price         NUMERIC,
                                                                 OUT account             transaction.account)
RETURNS transaction.account AS $def$
DECLARE
    v_r RECORD;
BEGIN
    -- This query not only fetches the account balance. It also works as lock
    -- to prevent deadlocks. It MUST BE THE FIRST QUERY in the function and
    -- it must use FOR UPDATE (instead of FOR NO KEY UPDATE).
    SELECT * INTO account
      FROM transaction.account a
     WHERE a.client_loginid=a_loginid
       AND a.currency_code=a_currency
       AND a.is_default
       FOR UPDATE;
    account.balance := coalesce(account.balance, 0);

    -- This is not really necessary because we have a constraint that ensures
    -- that balance>=0. But we have the balance anyway. So, we can check it also
    -- here and make the error handling on the Perl side easier.
    IF b_buy_price > account.balance THEN
        -- find pot. payout and count of expired bets
        SELECT INTO v_r coalesce(sum(payout_price), 0) AS potential_payout, count(*) AS cnt
          FROM bet.financial_market_bet
         WHERE account_id=account.id
           AND NOT is_sold
           AND expiry_time<now();
        RAISE EXCEPTION USING
            MESSAGE=format((SELECT explanation FROM betonmarkets.custom_pg_error_codes WHERE code='BI003'),
                           b_buy_price - account.balance, v_r.cnt, v_r.potential_payout),
            ERRCODE='BI003';
    END IF;
END
$def$ LANGUAGE plpgsql VOLATILE;

COMMIT;
