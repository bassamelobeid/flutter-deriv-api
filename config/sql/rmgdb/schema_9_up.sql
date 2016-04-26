BEGIN;

CREATE TABLE bet.spread_bet (
    financial_market_bet_id bigint NOT NULL PRIMARY KEY,
    amount_per_point numeric,
    stop_profit numeric,
    stop_loss numeric,
    stop_type text,
    spread numeric,
    spread_divisor numeric,
    CONSTRAINT basic_validation
         CHECK (amount_per_point > 0 AND
                stop_profit > 0 AND
                stop_loss > 0)
);

ALTER TABLE ONLY bet.spread_bet
    ADD CONSTRAINT fk_spread_bet_financial_market_bet_id
    FOREIGN KEY (financial_market_bet_id)
    REFERENCES bet.financial_market_bet(id)
    ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY bet.bet_dictionary
    DROP CONSTRAINT IF EXISTS bet_dictionary_table_name_check;

ALTER TABLE ONLY bet.bet_dictionary
    ADD CONSTRAINT bet_dictionary_table_name_check
        CHECK (
               (table_name IN ('touch_bet',
                               'range_bet',
                               'higher_lower_bet',
                               'run_bet',
                               'legacy_bet',
                               'digit_bet',
                               'spread_bet')) IS TRUE
        );

ALTER TABLE ONLY bet.financial_market_bet
    DROP CONSTRAINT IF EXISTS pk_check_bet_class_value;

ALTER TABLE ONLY bet.financial_market_bet
    ADD CONSTRAINT pk_check_bet_class_value
        CHECK (
               (bet_class IN ('higher_lower_bet',
                              'range_bet',
                              'touch_bet',
                              'run_bet',
                              'legacy_bet',
                              'digit_bet',
                              'spread_bet')) IS TRUE
        ) NOT VALID;

ALTER TABLE ONLY bet.financial_market_bet
    DROP CONSTRAINT IF EXISTS basic_validation;

ALTER TABLE ONLY bet.financial_market_bet
    ADD CONSTRAINT basic_validation
        CHECK (
           (
            purchase_time < '2014-05-09 00:00:00'::TIMESTAMP
            OR bet_class='run_bet'
            OR (NOT is_sold
                OR 0 <= sell_price
                   AND (bet_class = 'spread_bet' OR sell_price <= payout_price)
                   AND round(sell_price, 2) = sell_price
                   AND purchase_time < sell_time)
            AND 0 < buy_price
            AND round(buy_price, 2) = buy_price
            AND purchase_time <= start_time
            AND (bet_class = 'spread_bet'
                 OR start_time <= expiry_time
                    AND purchase_time <= settlement_time
                    AND 0 < payout_price
                    AND round(payout_price, 2) = payout_price)
           ) IS TRUE
        ) NOT VALID;

ALTER TABLE ONLY bet.financial_market_bet
   DROP CONSTRAINT IF EXISTS pk_check_bet_params_payout_price;

CREATE TRIGGER prevent_action BEFORE DELETE ON bet.spread_bet
   FOR EACH STATEMENT EXECUTE PROCEDURE public.prevent_action();

INSERT INTO bet.bet_dictionary (bet_type,path_dependent,table_name)
VALUES ('SPREADU', false, 'spread_bet'),
       ('SPREADD', false, 'spread_bet');

GRANT SELECT, UPDATE, INSERT ON bet.spread_bet to read, write;

COMMIT;

SET statement_timeout TO 0;

BEGIN;

UPDATE pg_constraint
   SET convalidated=NOT EXISTS (
           SELECT *
             FROM bet.financial_market_bet
            WHERE NOT (
               (bet_class IN ('higher_lower_bet',
                              'range_bet',
                              'touch_bet',
                              'run_bet',
                              'legacy_bet',
                              'digit_bet',
                              'spread_bet')) IS TRUE
        )
       )
 WHERE NOT convalidated
   AND conrelid='bet.financial_market_bet'::REGCLASS::OID
   AND conname='pk_check_bet_class_value';

COMMIT;

BEGIN;

UPDATE pg_constraint
   SET convalidated=NOT EXISTS (
           SELECT *
             FROM bet.financial_market_bet
            WHERE NOT (
           (
            purchase_time < '2014-05-09 00:00:00'::TIMESTAMP
            OR bet_class='run_bet'
            OR (NOT is_sold
                OR 0 <= sell_price
                   AND (bet_class = 'spread_bet' OR sell_price <= payout_price)
                   AND round(sell_price, 2) = sell_price
                   AND purchase_time < sell_time)
            AND 0 < buy_price
            AND round(buy_price, 2) = buy_price
            AND purchase_time <= start_time
            AND (bet_class = 'spread_bet'
                 OR start_time <= expiry_time
                    AND purchase_time <= settlement_time
                    AND 0 < payout_price
                    AND round(payout_price, 2) = payout_price)
           ) IS TRUE
        )
       )
 WHERE NOT convalidated
   AND conrelid='bet.financial_market_bet'::REGCLASS::OID
   AND conname='basic_validation';

COMMIT;