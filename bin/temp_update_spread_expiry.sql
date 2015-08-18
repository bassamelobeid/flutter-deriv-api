BEGIN;

UPDATE bet.financial_market_bet
    SET expiry_time = start_time::timestamp + interval '365 days',
        settlement_time= start_time::timestamp + interval '365 days'
    WHERE bet_class='spread_bet'
        AND expiry_time is null;

COMMIT;
