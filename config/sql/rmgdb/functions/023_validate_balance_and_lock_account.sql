BEGIN;

SELECT r.*
  FROM (
    VALUES ('BI003', 'insufficient balance, need: %s, #open_bets: %s, pot_payout: %s')
  ) dat(code, explanation)
CROSS JOIN LATERAL betonmarkets.update_custom_pg_error_code(dat.code, dat.explanation) r;

-- Returns the account record complemented with the exchange rate to USD if there is enough
-- balance to withdraw b_buy_price. Otherwise an exception is thrown.
-- Upon return, the account record is locked FOR UPDATE.
CREATE OR REPLACE FUNCTION bet.validate_balance_and_lock_account(-- account
                                                                 a_loginid           VARCHAR(12),
                                                                 a_currency          VARCHAR(3),
                                                                 -- how much to withdraw
                                                                 b_buy_price         NUMERIC,
                                                                 -- time needed to get the exchange rate
                                                                 b_purchase_time     TIMESTAMP DEFAULT now(),
                                                             OUT account             transaction.account,
                                                             OUT rate                NUMERIC)
RETURNS RECORD AS $def$
DECLARE
    v_r RECORD;
BEGIN
    -- This query not only fetches the account balance. It also works as lock
    -- to prevent deadlocks. It MUST BE THE FIRST QUERY in the function and
    -- it must use FOR UPDATE (instead of FOR NO KEY UPDATE).
    -- NOTE: this does not lock the row from data_collection.exchange_rate
    --       due to the function call. A normal JOIN would lock that as well.
    SELECT INTO v_r a AS acc, e.rate AS rate
      FROM transaction.account a
     CROSS JOIN data_collection.exchangeToUSD_rate(a.currency_code, b_purchase_time) e(rate)
     WHERE a.client_loginid=a_loginid
       AND a.currency_code=a_currency
       FOR UPDATE;
    account := v_r.acc;
    rate    := coalesce(v_r.rate, 1);
    account.balance := coalesce(account.balance, 0);

    -- This is not really necessary because we have a constraint that ensures
    -- that balance>=0. But we have the balance anyway. So, we can check it also
    -- here and make the error handling on the Perl side easier.
    IF b_buy_price > account.balance THEN
        -- find pot. payout and count of expired bets
        SELECT INTO v_r coalesce(sum(b.payout_price), 0) AS potential_payout, count(*) AS cnt
          FROM bet.financial_market_bet b
         WHERE b.account_id=account.id
           AND NOT b.is_sold
           AND b.expiry_time<now();
        RAISE EXCEPTION USING
            MESSAGE=format((SELECT explanation FROM betonmarkets.custom_pg_error_codes WHERE code='BI003'),
                           b_buy_price - account.balance, v_r.cnt, v_r.potential_payout),
            ERRCODE='BI003';
    END IF;
END
$def$ LANGUAGE plpgsql VOLATILE;

COMMIT;
