BEGIN;

CREATE OR REPLACE FUNCTION bet.calculate_potential_losses(p_account transaction.account)
RETURNS NUMERIC AS $def$
    SELECT coalesce(sum(b.buy_price), 0)
      FROM bet.financial_market_bet b
     WHERE b.account_id=p_account.id
       AND NOT b.is_sold;
$def$ LANGUAGE sql STABLE;

COMMIT;
