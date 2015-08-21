SET statement_timeout = 0;

BEGIN;

UPDATE bet.financial_market_bet fmb
   SET expiry_time     = fmb.start_time::timestamp + interval '365 days',
       settlement_time = fmb.start_time::timestamp + interval '365 days',
       payout_price    = CASE WHEN chld.stop_type='dollar'
                              THEN chld.stop_profit
                              WHEN chld.stop_type='point'
                              THEN chld.stop_profit * chld.amount_per_point
                         END
  FROM bet.spread_bet chld
 WHERE fmb.id = chld.financial_market_bet_id
   AND fmb.bet_class='spread_bet'
   AND fmb.expiry_time IS NULL
   AND fmb.payout_price IS NULL
   AND fmb.is_sold;

COMMIT;

BEGIN;

UPDATE bet.financial_market_bet fmb
   SET expiry_time     = fmb.start_time::timestamp + interval '365 days',
       settlement_time = fmb.start_time::timestamp + interval '365 days',
       payout_price    = CASE WHEN chld.stop_type='dollar'
                              THEN chld.stop_profit
                              WHEN chld.stop_type='point'
                              THEN chld.stop_profit * chld.amount_per_point
                         END
  FROM bet.spread_bet chld
 WHERE fmb.id = chld.financial_market_bet_id
   AND fmb.bet_class='spread_bet'
   AND fmb.expiry_time IS NULL
   AND fmb.payout_price IS NULL;

COMMIT;
