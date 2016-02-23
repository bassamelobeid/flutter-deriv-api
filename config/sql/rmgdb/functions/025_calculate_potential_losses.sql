BEGIN;

CREATE OR REPLACE FUNCTION bet_v1.calculate_potential_losses(p_account transaction.account)
RETURNS NUMERIC AS $def$
    SELECT coalesce(sum(b.buy_price), 0)
      FROM bet.financial_market_bet
     WHERE account_id=p_account.id
       AND NOT is_sold;
$def$ LANGUAGE sql STABLE;

COMMIT;
