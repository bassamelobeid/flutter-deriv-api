BEGIN;

CREATE OR REPLACE FUNCTION bet.calculate_potential_losses(p_loginid VARCHAR(12))
RETURNS NUMERIC AS $def$
    SELECT coalesce(sum(b.buy_price * e.rate), 0)
      FROM bet.financial_market_bet b
      JOIN transaction.account a ON b.account_id=a.id
     CROSS JOIN data_collection.exchangeToUSD_rate(a.currency_code) e
     WHERE a.client_loginid=p_loginid
       AND NOT b.is_sold;
$def$ LANGUAGE sql STABLE;

COMMIT;
