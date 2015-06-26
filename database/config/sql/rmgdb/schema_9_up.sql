BEGIN;

CREATE TABLE bet.spread_bet (
    financial_market_bet_id bigint NOT NULL PRIMARY KEY,
    amount_per_point numeric,
    stop_profit numeric,
    stop_loss numeric,
    spread numeric,
    spread_divisor numeric,
    CONSTRAINT basic_validation CHECK ((amount_per_point > (0)::numeric) AND (stop_profit > (0)::numeric) AND (stop_loss > (0)::numeric))
);

ALTER TABLE ONLY bet.spread_bet
    ADD CONSTRAINT fk_spread_bet_financial_market_bet_id FOREIGN KEY (financial_market_bet_id) REFERENCES bet.financial_market_bet(id) ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY bet.bet_dictionary
    RENAME CONSTRAINT bet_dictionary_table_name_check TO bet_dictionary_table_name_check_old;

ALTER TABLE ONLY bet.bet_dictionary
    ADD CONSTRAINT bet_dictionary_table_name_check CHECK (((table_name)::text = ANY ((ARRAY['touch_bet'::character varying, 'range_bet'::character varying, 'higher_lower_bet'::character varying, 'run_bet'::character varying, 'legacy_bet'::character varying, 'digit_bet'::character varying, 'spread_bet'::character varying])::text[])));

ALTER TABLE ONLY bet.bet_dictionary
    DROP CONSTRAINT IF EXISTS  bet_dictionary_table_name_check_old RESTRICT;

ALTER TABLE ONLY bet.financial_market_bet
    RENAME CONSTRAINT pk_check_bet_class_value TO pk_check_bet_class_value_old;

ALTER TABLE ONLY bet.financial_market_bet
    ADD CONSTRAINT pk_check_bet_class_value CHECK (((bet_class)::text = ANY ((ARRAY['higher_lower_bet'::character varying, 'range_bet'::character varying, 'touch_bet'::character varying, 'run_bet'::character varying, 'legacy_bet'::character varying, 'digit_bet'::character varying, 'spread_bet'::character varying])::text[]))) NOT VALID;

ALTER TABLE ONLY bet.financial_market_bet
    DROP CONSTRAINT IF EXISTS  pk_check_bet_class_value_old RESTRICT;


CREATE TRIGGER prevent_action BEFORE DELETE ON bet.spread_bet FOR EACH STATEMENT EXECUTE PROCEDURE public.prevent_action();

INSERT INTO bet.bet_dictionary (bet_type,path_dependent,table_name) VALUES ('SPREADU', false, 'spread_bet');

INSERT INTO bet.bet_dictionary (bet_type,path_dependent,table_name) VALUES ('SPREADD', false, 'spread_bet');

COMMIT;
