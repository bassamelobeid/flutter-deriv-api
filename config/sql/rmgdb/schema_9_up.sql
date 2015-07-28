BEGIN;

CREATE TABLE bet.spread_bet (
    financial_market_bet_id bigint NOT NULL PRIMARY KEY,
    amount_per_point numeric,
    stop_profit numeric,
    stop_loss numeric,
    stop_type VARCHAR,
    spread numeric,
    spread_divisor numeric,
    CONSTRAINT basic_validation CHECK ((amount_per_point > (0)::numeric) AND (stop_profit > (0)::numeric) AND (stop_loss > (0)::numeric))
);

ALTER TABLE ONLY bet.spread_bet
    ADD CONSTRAINT fk_spread_bet_financial_market_bet_id FOREIGN KEY (financial_market_bet_id) REFERENCES bet.financial_market_bet(id) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY bet.bet_dictionary
    DROP CONSTRAINT IF EXISTS bet_dictionary_table_name_check RESTRICT;

ALTER TABLE ONLY bet.bet_dictionary
    ADD CONSTRAINT bet_dictionary_table_name_check CHECK (((table_name)::text = ANY ((ARRAY['touch_bet'::character varying, 'range_bet'::character varying, 'higher_lower_bet'::character varying, 'run_bet'::character varying, 'legacy_bet'::character varying, 'digit_bet'::character varying, 'spread_bet'::character varying])::text[])));

ALTER TABLE ONLY bet.financial_market_bet
    DROP CONSTRAINT IF EXISTS pk_check_bet_class_value RESTRICT;

ALTER TABLE ONLY bet.financial_market_bet
    ADD CONSTRAINT pk_check_bet_class_value CHECK (((bet_class)::text = ANY ((ARRAY['higher_lower_bet'::character varying, 'range_bet'::character varying, 'touch_bet'::character varying, 'run_bet'::character varying, 'legacy_bet'::character varying, 'digit_bet'::character varying, 'spread_bet'::character varying])::text[]))) NOT VALID;

ALTER TABLE ONLY bet.financial_market_bet
    DROP CONSTRAINT IF EXISTS basic_validation RESTRICT;

ALTER TABLE ONLY bet.financial_market_bet
    ADD CONSTRAINT basic_validation CHECK (purchase_time < '2014-05-09 00:00:00'::timestamp without time zone OR (NOT is_sold OR 0::numeric <= sell_price AND (bet_class = 'spread_bet' OR sell_price <= payout_price) AND round(sell_price, 2) = sell_price AND purchase_time < sell_time) AND 0::numeric < buy_price AND (bet_class = 'spread_bet' OR 0::numeric < payout_price) AND round(buy_price, 2) = buy_price AND round(payout_price, 2) = payout_price AND purchase_time <= start_time AND ((bet_class = 'spread_bet' AND NOT is_sold) OR (start_time <= expiry_time AND purchase_time <= settlement_time))) NOT VALID;

ALTER TABLE ONLY bet.financial_market_bet
   DROP CONSTRAINT IF EXISTS pk_check_bet_params_payout_price RESTRICT;

ALTER TABLE ONLY bet.financial_market_bet
   ADD CONSTRAINT pk_check_bet_params_payout_price CHECK ((((bet_class)::text = 'legacy_bet'::text) OR (bet_class = 'spread_bet' OR payout_price IS NOT NULL)));

CREATE TRIGGER prevent_action BEFORE DELETE ON bet.spread_bet FOR EACH STATEMENT EXECUTE PROCEDURE public.prevent_action();

INSERT INTO bet.bet_dictionary (bet_type,path_dependent,table_name) VALUES ('SPREADU', false, 'spread_bet');

INSERT INTO bet.bet_dictionary (bet_type,path_dependent,table_name) VALUES ('SPREADD', false, 'spread_bet');

GRANT SELECT, UPDATE, INSERT ON bet.spread_bet to read, write;

COMMIT;
